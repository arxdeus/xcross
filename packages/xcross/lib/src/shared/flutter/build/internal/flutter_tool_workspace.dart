import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/shared/flutter/flutter_workspace_overlay.dart';
import 'package:xcross/src/shared/flutter/flutter_workspace_readiness.dart';

@internal
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
      engineCache.host.paths.context.join(root, '.xcross-workspace-ready'),
    );
    if (marker.existsSync() &&
        await marker.readAsString() == _readyMarkerContents &&
        await FlutterWorkspaceReadiness(
          engineCache,
        ).isReady(flutterRoot: sourceRoot, workspaceRoot: root)) {
      return FlutterToolWorkspace._(
        flutterRoot: root,
        dart: _dartPath(sourceRoot, engineCache.host),
        flutterToolsSnapshot: _snapshotPath(sourceRoot, engineCache.host),
      );
    }
    await _deleteFailedWorkspace(engineCache, root);
    await engineCache.host.fileSystem.directory(root).create(recursive: true);
    try {
      await FlutterWorkspaceOverlay(
        engineCache,
      ).create(flutterRoot: sourceRoot, workspaceRoot: root);

      await marker.writeAsString(_readyMarkerContents);
      return FlutterToolWorkspace._(
        flutterRoot: root,
        dart: _dartPath(sourceRoot, engineCache.host),
        flutterToolsSnapshot: _snapshotPath(sourceRoot, engineCache.host),
      );
    } on Object {
      await _deleteFailedWorkspace(engineCache, root);
      rethrow;
    }
  }

  static String _dartPath(String flutterRoot, PlatformHostInterface host) =>
      host.paths.context.join(
        flutterRoot,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        host.paths.executableName('dart'),
      );

  static String _snapshotPath(String flutterRoot, PlatformHostInterface host) =>
      host.paths.context.join(
        flutterRoot,
        'bin',
        'cache',
        'flutter_tools.snapshot',
      );

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
  ) => engineCache.host.paths.context.join(
    engineCache.cacheRoot,
    engineCache.engineHash,
    'workspaces',
    'flutter',
    engineCache.hostArtifactPlatform,
    sha256
        .convert(utf8.encode(engineCache.host.paths.pathKey(flutterRoot)))
        .toString(),
  );
}
