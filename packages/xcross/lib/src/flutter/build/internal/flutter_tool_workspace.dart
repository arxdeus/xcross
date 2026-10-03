import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';

final class FlutterToolWorkspace {
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

  static Future<FlutterToolWorkspace> create({
    required String flutterRoot,
    required IosEngineCache engineCache,
  }) async {
    final sourceRoot = await Directory(flutterRoot).resolveSymbolicLinks();
    final root = _workspaceRoot(engineCache, sourceRoot);
    final marker = File(p.join(root, '.xcross-workspace-ready'));
    if (marker.existsSync() &&
        await _isReady(
          flutterRoot: sourceRoot,
          workspaceRoot: root,
          engineCache: engineCache,
        )) {
      return FlutterToolWorkspace._(
        flutterRoot: root,
        dart: _dartPath(flutterRoot),
        flutterToolsSnapshot: _snapshotPath(flutterRoot),
      );
    }
    await _deleteFailedWorkspace(root);
    await Directory(root).create(recursive: true);
    try {
      final cache = await _createCacheDirectory(root);
      await _overlaySdkMetadata(flutterRoot: sourceRoot, workspaceRoot: root);

      final sdkCache = p.join(sourceRoot, 'bin', 'cache');
      await _overlaySdkCache(
        sdkCache: sdkCache,
        workspaceCache: cache,
        engineCache: engineCache,
      );

      await marker.writeAsString('ready\n');
      return FlutterToolWorkspace._(
        flutterRoot: root,
        dart: _dartPath(flutterRoot),
        flutterToolsSnapshot: _snapshotPath(flutterRoot),
      );
    } on Object {
      await _deleteFailedWorkspace(root);
      rethrow;
    }
  }

  static String _dartPath(String flutterRoot) => p.join(
    flutterRoot,
    'bin',
    'cache',
    'dart-sdk',
    'bin',
    Platform.isWindows ? 'dart.exe' : 'dart',
  );

  static String _snapshotPath(String flutterRoot) =>
      p.join(flutterRoot, 'bin', 'cache', 'flutter_tools.snapshot');

  static Future<void> _deleteFailedWorkspace(String root) async {
    try {
      await Directory(root).delete(recursive: true);
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
    sha256.convert(utf8.encode(flutterRoot)).toString(),
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
        if (!await _matchesLink(entry.key, entry.value)) return false;
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
        if (!Directory(source).existsSync()) continue;
        await for (final entity in Directory(source).list(followLinks: false)) {
          final name = p.basename(entity.path);
          if (skip.contains(name)) continue;
          final target = p.join(destination, name);
          if (entity is File) {
            if (!File(target).existsSync() ||
                await File(target).length() != await entity.length()) {
              return false;
            }
          } else if (!await _matchesLink(target, entity.path)) {
            return false;
          }
        }
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static Future<bool> _matchesLink(String path, String target) async =>
      p.equals(
        await File(path).resolveSymbolicLinks(),
        await File(target).resolveSymbolicLinks(),
      );

  static Future<String> _createCacheDirectory(String workspaceRoot) async {
    final cache = p.join(workspaceRoot, 'bin', 'cache');
    await Directory(cache).create(recursive: true);
    return cache;
  }

  static Future<void> _overlaySdkMetadata({
    required String flutterRoot,
    required String workspaceRoot,
  }) async {
    await _link(
      p.join(workspaceRoot, 'packages'),
      p.join(flutterRoot, 'packages'),
    );

    final sdkInternal = p.join(flutterRoot, 'bin', 'internal');
    if (Directory(sdkInternal).existsSync()) {
      await _overlay(sdkInternal, p.join(workspaceRoot, 'bin', 'internal'));
    }
  }

  static Future<void> _overlaySdkCache({
    required String sdkCache,
    required String workspaceCache,
    required IosEngineCache engineCache,
  }) async {
    if (Directory(sdkCache).existsSync()) {
      await _overlay(sdkCache, workspaceCache, skip: const {'artifacts'});
    }

    final sdkArtifacts = p.join(sdkCache, 'artifacts');
    final artifacts = p.join(workspaceCache, 'artifacts');
    await Directory(artifacts).create(recursive: true);
    if (Directory(sdkArtifacts).existsSync()) {
      await _overlay(sdkArtifacts, artifacts, skip: const {'engine'});
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
    await Directory(engine).create(recursive: true);
    if (Directory(sdkEngine).existsSync()) {
      await _overlay(
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
      p.join(engine, 'ios'),
      p.dirname(engineCache.flutterXcframework),
    );
    await _link(
      p.join(engine, engineCache.hostEngineCacheDirectory),
      p.dirname(engineCache.vmSnapshotData),
    );
    await _link(
      p.join(engine, 'common'),
      p.dirname(engineCache.patchedSdkRoot),
    );
  }

  static Future<void> _overlay(
    String source,
    String destination, {
    Set<String> skip = const {},
  }) async {
    await for (final entity in Directory(source).list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (skip.contains(name)) {
        continue;
      }
      final target = p.join(destination, name);
      await Directory(destination).create(recursive: true);
      if (entity is File) {
        await entity.copy(target);
      } else {
        await _link(target, entity.path);
      }
    }
  }

  static Future<void> _link(String path, String target) async {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return;
    }
    await Directory(p.dirname(path)).create(recursive: true);
    if (!Platform.isWindows) {
      await Link(path).create(p.normalize(p.absolute(target)));
      return;
    }
    final arguments = [
      '/c',
      'mklink',
      if (Directory(target).existsSync()) '/J' else '/H',
      path,
      p.normalize(p.absolute(target)),
    ];
    final result = await ProcessRunner.run(
      await ProcessRunner.locateTool('cmd'),
      arguments,
    );
    if (result.exitCode != 0) {
      throw FileSystemException(result.stderr.trim(), path);
    }
  }
}
