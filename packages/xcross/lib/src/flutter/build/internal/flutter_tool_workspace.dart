import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';

final class FlutterToolWorkspace {
  static const _readyMarkerContents = 'ready-v2\n';

  const FlutterToolWorkspace._({
    required this.flutterRoot,
    required this.dart,
    required this.flutterToolsSnapshot,
  });

  final String flutterRoot;
  final String dart;
  final String flutterToolsSnapshot;

  /// Kept deliberately: see [_workspaceRoot].
  Future<void> dispose() async {}

  static Future<FlutterToolWorkspace> create<T extends PlatformHostInterface>({
    required String flutterRoot,
    required IosEngineCache<T> engineCache,
  }) async {
    final sourceRoot = await engineCache.host.fileSystem
        .directory(flutterRoot)
        .resolveSymbolicLinks();
    final root = _workspaceRoot(engineCache, sourceRoot);
    final marker = engineCache.host.fileSystem.file(
      p.join(root, '.xcross-workspace-ready'),
    );
    if (marker.existsSync() &&
        await marker.readAsString() == _readyMarkerContents &&
        await _isReady(
          flutterRoot: sourceRoot,
          workspaceRoot: root,
          engineCache: engineCache,
        )) {
      return FlutterToolWorkspace._(
        flutterRoot: root,
        dart: _dartPath(sourceRoot, engineCache.host),
        flutterToolsSnapshot: _snapshotPath(sourceRoot),
      );
    }
    await _deleteFailedWorkspace(engineCache, root);
    await engineCache.host.fileSystem.directory(root).create(recursive: true);
    try {
      final cache = await _createCacheDirectory(engineCache, root);
      await _overlaySdkMetadata(
        engineCache: engineCache,
        flutterRoot: sourceRoot,
        workspaceRoot: root,
      );

      final sdkCache = p.join(sourceRoot, 'bin', 'cache');
      await _overlaySdkCache(
        sdkCache: sdkCache,
        workspaceCache: cache,
        engineCache: engineCache,
      );

      await marker.writeAsString(_readyMarkerContents);
      return FlutterToolWorkspace._(
        flutterRoot: root,
        dart: _dartPath(sourceRoot, engineCache.host),
        flutterToolsSnapshot: _snapshotPath(sourceRoot),
      );
    } on Object {
      await _deleteFailedWorkspace(engineCache, root);
      rethrow;
    }
  }

  static String _dartPath(String flutterRoot, PlatformHostInterface host) =>
      p.join(
        flutterRoot,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        host.paths.executableName('dart'),
      );

  static String _snapshotPath(String flutterRoot) =>
      p.join(flutterRoot, 'bin', 'cache', 'flutter_tools.snapshot');

  static Future<void> _deleteFailedWorkspace(
    IosEngineCache engineCache,
    String root,
  ) async {
    try {
      await engineCache.host.fileSystem.directory(root).delete(recursive: true);
    } on FileSystemException {
      return;
    }
  }

  /// A fixed path, reused across builds rather than created per build.
  ///
  /// `flutter assemble` records the absolute path of every input it read in
  /// the dependency stamps under `.dart_tool/flutter_build`, and this
  /// workspace supplies the Dart SDK and engine artifacts it reads. A
  /// per-build temporary directory therefore guaranteed a stale stamp on the
  /// next run: the recorded paths no longer existed, so Flutter reported
  /// "invalidated build due to missing files" and re-ran the whole
  /// native-assets pipeline, including every build hook, every single time.
  ///
  /// The path is scoped by engine hash, so a different engine still gets its
  /// own workspace and its contents stay consistent with the artifacts they
  /// were overlaid from.
  static String _workspaceRoot(
    IosEngineCache engineCache,
    String flutterRoot,
  ) => p.join(
    engineCache.cacheRoot,
    engineCache.engineHash,
    'workspaces',
    'flutter',
    engineCache.hostArtifactPlatform,
    sha256
        .convert(utf8.encode(engineCache.host.paths.pathKey(flutterRoot)))
        .toString(),
  );

  static Future<bool> _isReady({
    required String flutterRoot,
    required String workspaceRoot,
    required IosEngineCache engineCache,
  }) async {
    final sdkCache = p.join(flutterRoot, 'bin', 'cache');
    final cache = p.join(workspaceRoot, 'bin', 'cache');
    final sdkArtifacts = p.join(sdkCache, 'artifacts');
    final artifacts = p.join(cache, 'artifacts');
    final engine = p.join(artifacts, 'engine');
    final links = {
      p.join(workspaceRoot, 'packages'): p.join(flutterRoot, 'packages'),
      p.join(cache, 'dart-sdk'): p.join(sdkCache, 'dart-sdk'),
      p.join(engine, 'ios'): p.dirname(engineCache.flutterXcframework),
      p.join(engine, engineCache.hostEngineCacheDirectory): p.dirname(
        engineCache.vmSnapshotData,
      ),
      p.join(engine, 'common'): p.dirname(engineCache.patchedSdkRoot),
    };
    try {
      for (final entry in links.entries) {
        if (!await _matchesLink(engineCache, entry.key, entry.value)) {
          return false;
        }
      }
      for (final (source, destination, skip) in [
        (
          p.join(flutterRoot, 'bin', 'internal'),
          p.join(workspaceRoot, 'bin', 'internal'),
          const <String>{},
        ),
        (sdkCache, cache, const {'artifacts'}),
        (sdkArtifacts, artifacts, const {'engine'}),
        (
          p.join(sdkArtifacts, 'engine'),
          engine,
          {'ios', engineCache.hostEngineCacheDirectory, 'common'},
        ),
      ]) {
        if (!engineCache.host.fileSystem.directory(source).existsSync()) {
          continue;
        }
        await for (final entity
            in engineCache.host.fileSystem
                .directory(source)
                .list(followLinks: false)) {
          final name = p.basename(entity.path);
          if (skip.contains(name)) continue;
          final target = p.join(destination, name);
          if (entity is File) {
            if (!engineCache.host.fileSystem.file(target).existsSync() ||
                await engineCache.host.fileSystem.file(target).length() !=
                    await entity.length()) {
              return false;
            }
          } else if (!await _matchesLink(engineCache, target, entity.path)) {
            return false;
          }
        }
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static Future<bool> _matchesLink(
    IosEngineCache engineCache,
    String path,
    String target,
  ) async =>
      engineCache.host.paths.pathKey(
        await engineCache.host.fileSystem.file(path).resolveSymbolicLinks(),
      ) ==
      engineCache.host.paths.pathKey(
        await engineCache.host.fileSystem.file(target).resolveSymbolicLinks(),
      );

  static Future<String> _createCacheDirectory(
    IosEngineCache engineCache,
    String workspaceRoot,
  ) async {
    final cache = p.join(workspaceRoot, 'bin', 'cache');
    await engineCache.host.fileSystem.directory(cache).create(recursive: true);
    return cache;
  }

  static Future<void> _overlaySdkMetadata({
    required IosEngineCache engineCache,
    required String flutterRoot,
    required String workspaceRoot,
  }) async {
    await _link(
      engineCache,
      p.join(workspaceRoot, 'packages'),
      p.join(flutterRoot, 'packages'),
    );

    final sdkInternal = p.join(flutterRoot, 'bin', 'internal');
    if (engineCache.host.fileSystem.directory(sdkInternal).existsSync()) {
      await _overlay(
        engineCache,
        sdkInternal,
        p.join(workspaceRoot, 'bin', 'internal'),
      );
    }
  }

  static Future<void> _overlaySdkCache({
    required String sdkCache,
    required String workspaceCache,
    required IosEngineCache engineCache,
  }) async {
    if (engineCache.host.fileSystem.directory(sdkCache).existsSync()) {
      await _overlay(
        engineCache,
        sdkCache,
        workspaceCache,
        skip: const {'artifacts'},
      );
    }

    final sdkArtifacts = p.join(sdkCache, 'artifacts');
    final artifacts = p.join(workspaceCache, 'artifacts');
    await engineCache.host.fileSystem
        .directory(artifacts)
        .create(recursive: true);
    if (engineCache.host.fileSystem.directory(sdkArtifacts).existsSync()) {
      await _overlay(
        engineCache,
        sdkArtifacts,
        artifacts,
        skip: const {'engine'},
      );
    }

    await _overlayEngine(
      sdkArtifacts: sdkArtifacts,
      artifacts: artifacts,
      engineCache: engineCache,
    );
  }

  static Future<void> _overlayEngine({
    required String sdkArtifacts,
    required String artifacts,
    required IosEngineCache engineCache,
  }) async {
    final sdkEngine = p.join(sdkArtifacts, 'engine');
    final engine = p.join(artifacts, 'engine');
    await engineCache.host.fileSystem.directory(engine).create(recursive: true);
    if (engineCache.host.fileSystem.directory(sdkEngine).existsSync()) {
      await _overlay(
        engineCache,
        sdkEngine,
        engine,
        skip: {'ios', engineCache.hostEngineCacheDirectory, 'common'},
      );
    }

    await _linkPatchedEngine(engine: engine, engineCache: engineCache);
  }

  static Future<void> _linkPatchedEngine({
    required String engine,
    required IosEngineCache engineCache,
  }) async {
    await _link(
      engineCache,
      p.join(engine, 'ios'),
      p.dirname(engineCache.flutterXcframework),
    );
    await _link(
      engineCache,
      p.join(engine, engineCache.hostEngineCacheDirectory),
      p.dirname(engineCache.vmSnapshotData),
    );
    await _link(
      engineCache,
      p.join(engine, 'common'),
      p.dirname(engineCache.patchedSdkRoot),
    );
  }

  static Future<void> _overlay(
    IosEngineCache engineCache,
    String source,
    String destination, {
    Set<String> skip = const {},
  }) async {
    await for (final entity
        in engineCache.host.fileSystem
            .directory(source)
            .list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (skip.contains(name)) {
        continue;
      }
      final target = p.join(destination, name);
      await engineCache.host.fileSystem
          .directory(destination)
          .create(recursive: true);
      if (entity is File) {
        await entity.copy(target);
      } else {
        await _link(engineCache, target, entity.path);
      }
    }
  }

  static Future<void> _link(
    IosEngineCache engineCache,
    String path,
    String target,
  ) async {
    if (FileSystemEntity.typeSync(
          engineCache.host.paths.ioPath(path),
          followLinks: false,
        ) !=
        FileSystemEntityType.notFound) {
      return;
    }
    await engineCache.host.fileSystem
        .directory(p.dirname(path))
        .create(recursive: true);
    final absoluteTarget = p.normalize(p.absolute(target));
    final resolvedTarget =
        FileSystemEntity.typeSync(
              engineCache.host.paths.ioPath(absoluteTarget),
            ) ==
            FileSystemEntityType.notFound
        ? absoluteTarget
        : await engineCache.host.fileSystem
              .file(absoluteTarget)
              .resolveSymbolicLinks();
    await engineCache.hostTools.link(path, resolvedTarget);
  }
}
