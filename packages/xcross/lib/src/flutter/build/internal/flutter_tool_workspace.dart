import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
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

  Future<void> dispose() => Directory(flutterRoot).delete(recursive: true);

  static Future<FlutterToolWorkspace> create({
    required String flutterRoot,
    required IosEngineCache engineCache,
  }) async {
    final parent = Directory(
      p.join(engineCache.cacheRoot, engineCache.engineHash, 'workspaces'),
    );
    await parent.create(recursive: true);
    final root = (await parent.createTemp('flutter-')).path;
    final cache = p.join(root, 'bin', 'cache');
    await Directory(cache).create(recursive: true);
    await _link(p.join(root, 'packages'), p.join(flutterRoot, 'packages'));
    final sdkInternal = p.join(flutterRoot, 'bin', 'internal');
    if (Directory(sdkInternal).existsSync()) {
      await _overlay(sdkInternal, p.join(root, 'bin', 'internal'));
    }

    final sdkCache = p.join(flutterRoot, 'bin', 'cache');
    if (Directory(sdkCache).existsSync()) {
      await _overlay(sdkCache, cache, skip: const {'artifacts'});
    }
    final sdkArtifacts = p.join(sdkCache, 'artifacts');
    final artifacts = p.join(cache, 'artifacts');
    await Directory(artifacts).create(recursive: true);
    if (Directory(sdkArtifacts).existsSync()) {
      await _overlay(sdkArtifacts, artifacts, skip: const {'engine'});
    }
    final sdkEngine = p.join(sdkArtifacts, 'engine');
    final engine = p.join(artifacts, 'engine');
    await Directory(engine).create(recursive: true);
    if (Directory(sdkEngine).existsSync()) {
      await _overlay(
        sdkEngine,
        engine,
        skip: {
          'ios',
          p.basename(p.dirname(engineCache.vmSnapshotData)),
          'common',
        },
      );
    }
    await _link(
      p.join(engine, 'ios'),
      p.dirname(engineCache.flutterXcframework),
    );
    await _link(
      p.join(engine, p.basename(p.dirname(engineCache.vmSnapshotData))),
      p.dirname(engineCache.vmSnapshotData),
    );
    await _link(
      p.join(engine, 'common'),
      p.dirname(engineCache.patchedSdkRoot),
    );

    return FlutterToolWorkspace._(
      flutterRoot: root,
      dart: p.join(
        flutterRoot,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      ),
      flutterToolsSnapshot: p.join(sdkCache, 'flutter_tools.snapshot'),
    );
  }

  static Future<void> _overlay(
    String source,
    String destination, {
    Set<String> skip = const {},
  }) async {
    await for (final entity in Directory(source).list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (skip.contains(name)) continue;
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
      await Link(path).create(target);
      return;
    }
    final arguments = [
      '/c',
      'mklink',
      if (Directory(target).existsSync()) '/J' else '/H',
      path,
      target,
    ];
    final result = await ProcessRunner.run(
      await ProcessRunner.locateTool('cmd'),
      arguments,
    );
    if (result.exitCode != 0) {
      throw FileSystemException(result.stderr.toString().trim(), path);
    }
  }
}
