import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/ios_engine_cache.dart';

@internal
final class FlutterWorkspaceReadiness<T extends PlatformHostInterface> {
  const FlutterWorkspaceReadiness(this.engineCache);
  final IosEngineCache<T> engineCache;
  p.Context get paths => engineCache.host.paths.context;
  HostFileSystemInterface get fileSystem => engineCache.host.fileSystem;

  Future<bool> isReady({
    required String flutterRoot,
    required String workspaceRoot,
  }) async {
    final sdkCache = paths.join(flutterRoot, 'bin', 'cache');
    final cache = paths.join(workspaceRoot, 'bin', 'cache');
    final sdkArtifacts = paths.join(sdkCache, 'artifacts');
    final artifacts = paths.join(cache, 'artifacts');
    final engine = paths.join(artifacts, 'engine');
    final links = {
      paths.join(workspaceRoot, 'packages'): paths.join(
        flutterRoot,
        'packages',
      ),
      paths.join(cache, 'dart-sdk'): paths.join(sdkCache, 'dart-sdk'),
      paths.join(engine, 'ios'): paths.dirname(engineCache.flutterXcframework),
      paths.join(engine, engineCache.hostEngineCacheDirectory): paths.dirname(
        engineCache.vmSnapshotData,
      ),
      paths.join(engine, 'common'): paths.dirname(engineCache.patchedSdkRoot),
    };
    try {
      for (final entry in links.entries) {
        if (!await _matchesLink(entry.key, entry.value)) {
          return false;
        }
      }
      for (final (source, destination, skip) in [
        (
          paths.join(flutterRoot, 'bin', 'internal'),
          paths.join(workspaceRoot, 'bin', 'internal'),
          const <String>{},
        ),
        (sdkCache, cache, const {'artifacts'}),
        (sdkArtifacts, artifacts, const {'engine'}),
        (
          paths.join(sdkArtifacts, 'engine'),
          engine,
          {'ios', engineCache.hostEngineCacheDirectory, 'common'},
        ),
      ]) {
        if (!fileSystem.directory(source).existsSync()) {
          continue;
        }
        await for (final entity
            in fileSystem.directory(source).list(followLinks: false)) {
          final name = paths.basename(entity.path);
          if (skip.contains(name)) continue;
          final target = paths.join(destination, name);
          if (entity is File) {
            if (!fileSystem.file(target).existsSync() ||
                await fileSystem.file(target).length() !=
                    await entity.length()) {
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

  Future<bool> _matchesLink(String path, String target) async =>
      engineCache.host.paths.pathKey(
        await fileSystem.file(path).resolveSymbolicLinks(),
      ) ==
      engineCache.host.paths.pathKey(
        await fileSystem.file(target).resolveSymbolicLinks(),
      );
}
