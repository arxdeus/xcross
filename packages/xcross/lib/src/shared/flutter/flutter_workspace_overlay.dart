import 'dart:io';

import 'package:cli_kit/shared/platform/file_system_inspection.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';

/// One entry of a flutter_tools workspace, in creation order.
@internal
sealed class FlutterWorkspaceEntry {
  const FlutterWorkspaceEntry(this.path);
  final String path;
}

/// A real directory. When [exact], it holds nothing but the entries planned
/// below it.
@internal
final class FlutterWorkspaceDirectory extends FlutterWorkspaceEntry {
  const FlutterWorkspaceDirectory(super.path, {this.exact = false});
  final bool exact;
}

/// A link to a read-only [target] that flutter_tools never writes through.
@internal
final class FlutterWorkspaceLink extends FlutterWorkspaceEntry {
  const FlutterWorkspaceLink(super.path, this.target);
  final String target;
}

/// A private copy of [source], so flutter_tools may rewrite it.
@internal
final class FlutterWorkspaceCopy extends FlutterWorkspaceEntry {
  const FlutterWorkspaceCopy(super.path, this.source);
  final String source;
}

/// A file xcross writes itself, such as a stamp.
@internal
final class FlutterWorkspaceFile extends FlutterWorkspaceEntry {
  const FlutterWorkspaceFile(super.path, this.contents);
  final String contents;
}

/// Lays out a `FLUTTER_ROOT` for flutter_tools that reads the Flutter SDK
/// and the engine artifacts of [engineCache] without ever writing to them.
///
/// Every directory flutter_tools may write into is real, and so is every
/// file it may rewrite. Only read-only leaves are links. The iOS engine
/// directories and the stamps flutter_tools checks them against
/// (`ios-sdk.stamp`) are xcross's own, so flutter_tools considers the iOS
/// artifacts current and never downloads them into the workspace, the SDK
/// or the xcross cache.
@internal
final class FlutterWorkspaceOverlay<T extends PlatformHostInterface> {
  const FlutterWorkspaceOverlay(this.engineCache);
  final IosEngineCache<T> engineCache;
  p.Context get paths => engineCache.host.paths.context;
  HostFileSystemInterface get fileSystem => engineCache.host.fileSystem;

  /// Engine directories flutter_tools' `ios-sdk` artifact set requires,
  /// each with a `LICENSE`.
  static final iosEngineDirectories = [
    for (final mode in FlutterBuildMode.values) mode.engineArtifact,
  ];

  /// Stamps xcross writes with the engine revision, because the workspace
  /// supplies the artifacts they vouch for.
  static const engineStamps = [
    'engine',
    'ios-sdk',
    'flutter_sdk',
    'font-subset',
  ];

  Future<void> create({
    required String flutterRoot,
    required String workspaceRoot,
  }) async {
    for (final entry in plan(
      flutterRoot: flutterRoot,
      workspaceRoot: workspaceRoot,
    )) {
      await _apply(entry);
    }
  }

  List<FlutterWorkspaceEntry> plan({
    required String flutterRoot,
    required String workspaceRoot,
  }) {
    final sdkCache = paths.join(flutterRoot, 'bin', 'cache');
    final cache = paths.join(workspaceRoot, 'bin', 'cache');
    final sdkArtifacts = paths.join(sdkCache, 'artifacts');
    final artifacts = paths.join(cache, 'artifacts');
    final engine = paths.join(artifacts, 'engine');
    final license = _license(flutterRoot);
    final hostDirectory = engineCache.hostEngineCacheDirectory;
    final stamps = {for (final name in engineStamps) '$name.stamp'};
    return [
      FlutterWorkspaceDirectory(cache),
      FlutterWorkspaceLink(
        paths.join(workspaceRoot, 'packages'),
        paths.join(flutterRoot, 'packages'),
      ),
      if (fileSystem.file(paths.join(flutterRoot, 'LICENSE')).existsSync())
        FlutterWorkspaceCopy(
          paths.join(workspaceRoot, 'LICENSE'),
          paths.join(flutterRoot, 'LICENSE'),
        ),
      ..._overlay(
        paths.join(flutterRoot, 'bin', 'internal'),
        paths.join(workspaceRoot, 'bin', 'internal'),
      ),
      ..._overlay(
        sdkCache,
        cache,
        skip: {'artifacts', 'downloads', 'pkg', ...stamps},
      ),
      FlutterWorkspaceDirectory(paths.join(cache, 'downloads')),
      FlutterWorkspaceDirectory(paths.join(cache, 'pkg'), exact: true),
      ..._leaves(paths.join(sdkCache, 'pkg'), paths.join(cache, 'pkg')),
      for (final name in engineStamps)
        FlutterWorkspaceFile(
          paths.join(cache, '$name.stamp'),
          engineCache.engineHash,
        ),
      FlutterWorkspaceDirectory(artifacts),
      ..._overlay(
        sdkArtifacts,
        artifacts,
        skip: const {'engine'},
        realDirectories: true,
      ),
      FlutterWorkspaceDirectory(engine),
      ..._overlay(
        paths.join(sdkArtifacts, 'engine'),
        engine,
        skip: {...iosEngineDirectories, hostDirectory, 'common'},
      ),
      for (final name in iosEngineDirectories) ...[
        FlutterWorkspaceDirectory(paths.join(engine, name), exact: true),
        // The bundle target xcross assembles unpacks `ios` whatever the
        // mode, so it serves the build's own engine.
        if (name == FlutterBuildMode.debug.engineArtifact ||
            name == engineCache.engineArtifact)
          ..._leaves(
            engineCache.engineDirectory,
            paths.join(engine, name),
            skip: const {'LICENSE'},
          ),
        if (license != null)
          FlutterWorkspaceCopy(paths.join(engine, name, 'LICENSE'), license),
      ],
      FlutterWorkspaceDirectory(paths.join(engine, hostDirectory), exact: true),
      ..._leaves(
        paths.dirname(engineCache.vmSnapshotData),
        paths.join(engine, hostDirectory),
      ),
      ..._leaves(
        paths.dirname(engineCache.fontSubset),
        paths.join(engine, hostDirectory),
        skip: _names(paths.dirname(engineCache.vmSnapshotData)),
      ),
      FlutterWorkspaceDirectory(paths.join(engine, 'common'), exact: true),
      // Only the mode's own platform kernel, so another mode downloading
      // its kernel next to it leaves this workspace intact.
      ..._leaves(
        paths.dirname(engineCache.patchedSdkRoot),
        paths.join(engine, 'common'),
        skip: {
          for (final mode in FlutterBuildMode.values)
            if (mode.patchedSdk != engineCache.mode.patchedSdk) mode.patchedSdk,
        },
      ),
    ];
  }

  /// The license flutter_tools copies into each iOS engine directory: the
  /// SDK's own, else the one shipped with the engine.
  String? _license(String flutterRoot) {
    for (final candidate in [
      paths.join(flutterRoot, 'LICENSE'),
      paths.join(engineCache.engineDirectory, 'LICENSE'),
    ]) {
      if (fileSystem.file(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Copies the files of [source] and links its directories, judging each
  /// entry by what it resolves to: a linked file is still copied. With
  /// [realDirectories], each directory is real and links its entries
  /// instead, so flutter_tools can refresh it in place.
  List<FlutterWorkspaceEntry> _overlay(
    String source,
    String destination, {
    Set<String> skip = const {},
    bool realDirectories = false,
  }) {
    final directory = fileSystem.directory(source);
    if (!directory.existsSync()) return const [];
    return [
      FlutterWorkspaceDirectory(destination),
      for (final entity in _sorted(directory, skip: skip))
        if (fileSystem.typeSync(entity.path) == FileSystemEntityType.file)
          FlutterWorkspaceCopy(
            paths.join(destination, paths.basename(entity.path)),
            entity.path,
          )
        else if (realDirectories) ...[
          FlutterWorkspaceDirectory(
            paths.join(destination, paths.basename(entity.path)),
            exact: true,
          ),
          ..._leaves(
            entity.path,
            paths.join(destination, paths.basename(entity.path)),
          ),
        ] else
          FlutterWorkspaceLink(
            paths.join(destination, paths.basename(entity.path)),
            entity.path,
          ),
    ];
  }

  /// Links every entry of the read-only [source].
  List<FlutterWorkspaceEntry> _leaves(
    String source,
    String destination, {
    Set<String> skip = const {},
  }) {
    final directory = fileSystem.directory(source);
    if (!directory.existsSync()) return const [];
    return [
      for (final entity in _sorted(directory, skip: skip))
        FlutterWorkspaceLink(
          paths.join(destination, paths.basename(entity.path)),
          entity.path,
        ),
    ];
  }

  Set<String> _names(String path) {
    final directory = fileSystem.directory(path);
    if (!directory.existsSync()) return const {};
    return {
      for (final entity in directory.listSync(followLinks: false))
        paths.basename(entity.path),
    };
  }

  List<FileSystemEntity> _sorted(
    Directory directory, {
    Set<String> skip = const {},
  }) => [
    for (final entity in directory.listSync(followLinks: false))
      if (!skip.contains(paths.basename(entity.path))) entity,
  ]..sort((a, b) => a.path.compareTo(b.path));

  Future<void> _apply(FlutterWorkspaceEntry entry) async {
    final path = entry.path;
    if (fileSystem.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return;
    }
    await fileSystem.directory(paths.dirname(path)).create(recursive: true);
    switch (entry) {
      case FlutterWorkspaceDirectory():
        await fileSystem.directory(path).create();
      case FlutterWorkspaceCopy(:final source):
        await fileSystem.file(source).copy(engineCache.host.paths.ioPath(path));
      case FlutterWorkspaceFile(:final contents):
        await fileSystem.file(path).writeAsString(contents);
      case FlutterWorkspaceLink(:final target):
        final absoluteTarget = paths.normalize(paths.absolute(target));
        final resolvedTarget =
            fileSystem.typeSync(absoluteTarget) == FileSystemEntityType.notFound
            ? absoluteTarget
            : await fileSystem.file(absoluteTarget).resolveSymbolicLinks();
        await engineCache.hostTools.link(path, resolvedTarget);
    }
  }
}
