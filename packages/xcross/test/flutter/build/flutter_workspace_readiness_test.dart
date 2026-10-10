import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/internal/flutter_tool_workspace.dart';

import 'support/native_flutter_fixtures.dart';

void main() {
  test('migrates legacy ready overlays before aliases change', () async {
    if (Platform.isWindows) return;
    final tmp = await Directory.systemTemp.createTemp(
      'workspace_legacy_ready-',
    );
    try {
      final cacheRoot = p.join(tmp.path, 'cache');
      final firstCache = workspaceSdk(
        p.join(tmp.path, 'sdk-a'),
        cacheRoot,
        'sdk-a',
        sdkLocalEngine: true,
      );
      final secondCache = workspaceSdk(
        p.join(tmp.path, 'sdk-b'),
        cacheRoot,
        'sdk-b',
        sdkLocalEngine: true,
      );
      final untouched = File(p.join(cacheRoot, 'unrelated'))
        ..createSync(recursive: true)
        ..writeAsStringSync('keep');
      final alias = Link(p.join(tmp.path, 'alias'))
        ..createSync(firstCache.flutterRoot);
      final aliasCache = nativeLinuxEngineCache(
        flutterRoot: alias.path,
        cacheRoot: cacheRoot,
      );
      final legacy = await FlutterToolWorkspace.create(
        flutterRoot: alias.path,
        engineCache: aliasCache,
      );
      final engine = p.join(
        legacy.flutterRoot,
        'bin',
        'cache',
        'artifacts',
        'engine',
      );
      for (final name in ['ios', 'linux-arm64', 'common']) {
        await Directory(p.join(engine, name)).delete(recursive: true);
        await Link(p.join(engine, name)).create(
          p.join(alias.path, 'bin', 'cache', 'artifacts', 'engine', name),
        );
      }
      final marker = File(p.join(legacy.flutterRoot, '.xcross-workspace-ready'))
        ..writeAsStringSync('ready\n');
      final migrated = await FlutterToolWorkspace.create(
        flutterRoot: alias.path,
        engineCache: aliasCache,
      );
      expect(migrated.flutterRoot, legacy.flutterRoot);
      expect(marker.readAsStringSync(), 'ready-v3\n');
      expect(untouched.readAsStringSync(), 'keep');
      expectSelfContainedWorkspace(migrated, firstCache);
      for (final removeAlias in [false, true]) {
        await alias.delete();
        if (!removeAlias) await alias.create(secondCache.flutterRoot);
        expectWorkspaceSdk(migrated, 'sdk-a');
        for (final relative in [
          p.join('ios', 'Flutter.xcframework', 'source'),
          p.join('linux-arm64', 'vm_isolate_snapshot.bin'),
          p.join('common', 'flutter_patched_sdk', 'source'),
        ]) {
          expect(File(p.join(engine, relative)).readAsStringSync(), 'sdk-a');
        }
      }
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  for (final (staleEntry, dangling) in [
    (p.join('packages'), false),
    (p.join('bin', 'cache', 'dart-sdk'), false),
    (p.join('bin', 'cache', 'dart-sdk'), true),
    (p.join('bin', 'cache', 'artifacts', 'fonts', 'source'), false),
    (
      p.join(
        'bin',
        'cache',
        'artifacts',
        'engine',
        'linux-arm64',
        'vm_isolate_snapshot.bin',
      ),
      false,
    ),
    (
      p.join(
        'bin',
        'cache',
        'artifacts',
        'engine',
        'ios',
        'Flutter.xcframework',
      ),
      false,
    ),
    (
      p.join(
        'bin',
        'cache',
        'artifacts',
        'engine',
        'common',
        'flutter_patched_sdk',
        'source',
      ),
      false,
    ),
    (
      p.join('bin', 'cache', 'artifacts', 'engine', 'ios-release', 'LICENSE'),
      false,
    ),
    (p.join('bin', 'cache', 'ios-sdk.stamp'), false),
    (p.join('bin', 'cache', 'flutter_tools.snapshot'), false),
    (p.join('bin', 'internal', 'engine.version'), false),
  ]) {
    test(
      'repairs a ready workspace with stale $staleEntry dangling: $dangling',
      () async {
        if (Platform.isWindows) return;
        final tmp = await Directory.systemTemp.createTemp('workspace_stale-');
        try {
          final cache = workspaceSdk(
            p.join(tmp.path, 'sdk'),
            p.join(tmp.path, 'cache'),
            'sdk',
          );
          final first = await FlutterToolWorkspace.create(
            flutterRoot: cache.flutterRoot,
            engineCache: cache,
          );
          final stalePath = p.join(first.flutterRoot, staleEntry);
          if (FileSystemEntity.isLinkSync(stalePath)) {
            await Link(stalePath).delete();
            final wrongTarget = Directory(p.join(tmp.path, 'wrong-target'))
              ..createSync();
            await Link(stalePath).create(wrongTarget.path);
            if (dangling) await wrongTarget.delete();
          } else {
            await File(stalePath).delete();
          }
          final second = await FlutterToolWorkspace.create(
            flutterRoot: cache.flutterRoot,
            engineCache: cache,
          );

          expect(second.flutterRoot, first.flutterRoot);
          expectWorkspaceSdk(second, 'sdk');
          expect(
            File(
              p.join(second.flutterRoot, 'bin', 'internal', 'engine.version'),
            ).readAsStringSync(),
            'engine-hash',
          );
          expect(
            File(
              p.join(
                second.flutterRoot,
                'bin',
                'cache',
                'artifacts',
                'engine',
                'linux-arm64',
                'vm_isolate_snapshot.bin',
              ),
            ).readAsStringSync(),
            'host',
          );
          final engine = p.join(
            second.flutterRoot,
            'bin',
            'cache',
            'artifacts',
            'engine',
          );
          expect(
            await Directory(
              p.join(engine, 'ios', 'Flutter.xcframework'),
            ).resolveSymbolicLinks(),
            await Directory(cache.flutterXcframework).resolveSymbolicLinks(),
          );
          final patchedSdk = p.join(engine, 'common', 'flutter_patched_sdk');
          expect(
            FileSystemEntity.typeSync(patchedSdk, followLinks: false),
            FileSystemEntityType.directory,
          );
          expect(
            await File(p.join(patchedSdk, 'source')).resolveSymbolicLinks(),
            await File(
              p.join(cache.patchedSdkRoot, 'source'),
            ).resolveSymbolicLinks(),
          );
          expectSelfContainedWorkspace(second, cache);
        } finally {
          await tmp.delete(recursive: true);
        }
      },
    );
  }

  test('isolates engine versions at the same SDK root', () async {
    final tmp = await Directory.systemTemp.createTemp('workspace_engines-');
    try {
      final cache = workspaceSdk(
        p.join(tmp.path, 'sdk'),
        p.join(tmp.path, 'cache'),
        'sdk',
      );
      final first = await FlutterToolWorkspace.create(
        flutterRoot: cache.flutterRoot,
        engineCache: cache,
      );
      File(
        p.join(cache.flutterRoot, 'bin', 'internal', 'engine.version'),
      ).writeAsStringSync('other-engine');
      Directory(cache.flutterXcframework).createSync(recursive: true);
      Directory(p.dirname(cache.vmSnapshotData)).createSync(recursive: true);
      Directory(cache.patchedSdkRoot).createSync(recursive: true);
      final second = await FlutterToolWorkspace.create(
        flutterRoot: cache.flutterRoot,
        engineCache: cache,
      );

      expect(second.flutterRoot, isNot(first.flutterRoot));
      expect(
        File(
          p.join(first.flutterRoot, 'bin', 'internal', 'engine.version'),
        ).readAsStringSync(),
        'engine-hash',
      );
      expect(
        File(
          p.join(second.flutterRoot, 'bin', 'internal', 'engine.version'),
        ).readAsStringSync(),
        'other-engine',
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test(
    'creates a writable Flutter tool workspace without changing SDK',
    () async {
      if (Platform.isWindows) return;
      final tmp = await Directory.systemTemp.createTemp(
        'flutter_workspace_test-',
      );
      try {
        final flutterRoot = p.join(tmp.path, 'flutter');
        final cacheRoot = p.join(tmp.path, 'cache');
        final sdkCache = Directory(p.join(flutterRoot, 'bin', 'cache'))
          ..createSync(recursive: true);
        Directory(p.join(flutterRoot, 'packages')).createSync();
        File(
          p.join(flutterRoot, 'bin', 'flutter'),
        ).writeAsStringSync('flutter');
        File(p.join(flutterRoot, 'bin', 'internal', 'engine.version'))
          ..createSync(recursive: true)
          ..writeAsStringSync('engine-hash\n');
        File(
          p.join(sdkCache.path, 'flutter_tools.snapshot'),
        ).writeAsStringSync('snapshot');
        Directory(p.join(sdkCache.path, 'dart-sdk')).createSync();
        final engineCache = nativeLinuxEngineCache(
          flutterRoot: flutterRoot,
          cacheRoot: cacheRoot,
        );
        Directory(engineCache.flutterXcframework).createSync(recursive: true);
        final before = await nativeAssetTree(flutterRoot);

        final workspace = await FlutterToolWorkspace.create(
          flutterRoot: flutterRoot,
          engineCache: engineCache,
        );

        expect(workspace.flutterRoot, isNot(flutterRoot));
        expect(
          await Directory(
            p.join(workspace.flutterRoot, 'packages'),
          ).resolveSymbolicLinks(),
          await Directory(
            p.join(flutterRoot, 'packages'),
          ).resolveSymbolicLinks(),
        );
        expect(
          File(
            p.join(workspace.flutterRoot, 'bin', 'internal', 'engine.version'),
          ).readAsStringSync(),
          'engine-hash\n',
        );
        expect(
          Directory(
            p.join(
              workspace.flutterRoot,
              'bin',
              'cache',
              'artifacts',
              'engine',
              'ios',
              'Flutter.xcframework',
            ),
          ).existsSync(),
          isTrue,
        );
        expect(await nativeAssetTree(flutterRoot), before);
      } finally {
        await tmp.delete(recursive: true);
      }
    },
  );

  test('reuses one workspace path across builds', () async {
    final tmp = await Directory.systemTemp.createTemp('flutter_workspace_id-');
    try {
      final flutterRoot = p.join(tmp.path, 'flutter');
      final sdkCache = Directory(p.join(flutterRoot, 'bin', 'cache'))
        ..createSync(recursive: true);
      Directory(p.join(flutterRoot, 'packages')).createSync();
      File(p.join(flutterRoot, 'bin', 'internal', 'engine.version'))
        ..createSync(recursive: true)
        ..writeAsStringSync('engine-hash\n');
      File(
        p.join(sdkCache.path, 'flutter_tools.snapshot'),
      ).writeAsStringSync('snapshot');
      Directory(p.join(sdkCache.path, 'dart-sdk')).createSync();
      final engineCache = nativeLinuxEngineCache(
        flutterRoot: flutterRoot,
        cacheRoot: p.join(tmp.path, 'cache'),
      );
      Directory(engineCache.flutterXcframework).createSync(recursive: true);
      Directory(
        p.dirname(engineCache.vmSnapshotData),
      ).createSync(recursive: true);
      Directory(engineCache.patchedSdkRoot).createSync(recursive: true);

      final first = await FlutterToolWorkspace.create(
        flutterRoot: flutterRoot,
        engineCache: engineCache,
      );
      final sentinel = File(p.join(first.flutterRoot, 'retained'))
        ..writeAsStringSync('retained');
      await first.dispose();
      final second = await FlutterToolWorkspace.create(
        flutterRoot: flutterRoot,
        engineCache: engineCache,
      );

      expect(second.flutterRoot, first.flutterRoot);
      expect(sentinel.readAsStringSync(), 'retained');
      expect(
        Directory(first.flutterRoot).existsSync(),
        isTrue,
        reason: 'dispose must not remove the reusable workspace',
      );
      expect(
        File(
          p.join(second.flutterRoot, 'bin', 'internal', 'engine.version'),
        ).readAsStringSync(),
        'engine-hash\n',
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  });
}
