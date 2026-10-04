import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';

final class FlutterWorkspaceOverlay<T extends PlatformHostInterface> {
  const FlutterWorkspaceOverlay(this.engineCache);
  final IosEngineCache<T> engineCache;
  p.Context get paths => engineCache.host.paths.context;
  HostFileSystemInterface get fileSystem => engineCache.host.fileSystem;

  Future<void> create({
    required String flutterRoot,
    required String workspaceRoot,
  }) async {
    final cache = await _createCacheDirectory(workspaceRoot);
    await _overlaySdkMetadata(
      flutterRoot: flutterRoot,
      workspaceRoot: workspaceRoot,
    );
    await _overlaySdkCache(
      sdkCache: paths.join(flutterRoot, 'bin', 'cache'),
      workspaceCache: cache,
    );
  }

  Future<String> _createCacheDirectory(String workspaceRoot) async {
    final cache = paths.join(workspaceRoot, 'bin', 'cache');
    await fileSystem.directory(cache).create(recursive: true);
    return cache;
  }

  Future<void> _overlaySdkMetadata({
    required String flutterRoot,
    required String workspaceRoot,
  }) async {
    await _link(
      paths.join(workspaceRoot, 'packages'),
      paths.join(flutterRoot, 'packages'),
    );

    final sdkInternal = paths.join(flutterRoot, 'bin', 'internal');
    if (fileSystem.directory(sdkInternal).existsSync()) {
      await _overlay(sdkInternal, paths.join(workspaceRoot, 'bin', 'internal'));
    }
  }

  Future<void> _overlaySdkCache({
    required String sdkCache,
    required String workspaceCache,
  }) async {
    if (fileSystem.directory(sdkCache).existsSync()) {
      await _overlay(sdkCache, workspaceCache, skip: const {'artifacts'});
    }

    final sdkArtifacts = paths.join(sdkCache, 'artifacts');
    final artifacts = paths.join(workspaceCache, 'artifacts');
    await fileSystem.directory(artifacts).create(recursive: true);
    if (fileSystem.directory(sdkArtifacts).existsSync()) {
      await _overlay(sdkArtifacts, artifacts, skip: const {'engine'});
    }

    await _overlayEngine(sdkArtifacts: sdkArtifacts, artifacts: artifacts);
  }

  Future<void> _overlayEngine({
    required String sdkArtifacts,
    required String artifacts,
  }) async {
    final sdkEngine = paths.join(sdkArtifacts, 'engine');
    final engine = paths.join(artifacts, 'engine');
    await fileSystem.directory(engine).create(recursive: true);
    if (fileSystem.directory(sdkEngine).existsSync()) {
      await _overlay(
        sdkEngine,
        engine,
        skip: {'ios', engineCache.hostEngineCacheDirectory, 'common'},
      );
    }

    await _linkPatchedEngine(engine: engine);
  }

  Future<void> _linkPatchedEngine({required String engine}) async {
    await _link(
      paths.join(engine, 'ios'),
      paths.dirname(engineCache.flutterXcframework),
    );
    await _link(
      paths.join(engine, engineCache.hostEngineCacheDirectory),
      paths.dirname(engineCache.vmSnapshotData),
    );
    await _link(
      paths.join(engine, 'common'),
      paths.dirname(engineCache.patchedSdkRoot),
    );
  }

  Future<void> _overlay(
    String source,
    String destination, {
    Set<String> skip = const {},
  }) async {
    await for (final entity
        in fileSystem.directory(source).list(followLinks: false)) {
      final name = paths.basename(entity.path);
      if (skip.contains(name)) {
        continue;
      }
      final target = paths.join(destination, name);
      await fileSystem.directory(destination).create(recursive: true);
      if (entity is File) {
        await entity.copy(engineCache.host.paths.ioPath(target));
      } else {
        await _link(target, entity.path);
      }
    }
  }

  Future<void> _link(String path, String target) async {
    if (fileSystem.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return;
    }
    await fileSystem.directory(paths.dirname(path)).create(recursive: true);
    final absoluteTarget = paths.normalize(paths.absolute(target));
    final resolvedTarget =
        fileSystem.typeSync(absoluteTarget) == FileSystemEntityType.notFound
        ? absoluteTarget
        : await fileSystem.file(absoluteTarget).resolveSymbolicLinks();
    await engineCache.hostTools.link(path, resolvedTarget);
  }
}
