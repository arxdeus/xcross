import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/internal/flutter_tool_workspace.dart';
import 'package:xcross/src/shared/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';

import 'support/native_flutter_fixtures.dart';

void main() {
  late Directory tmp;
  late String sdk;
  late String cacheRoot;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('workspace_isolation-');
    sdk = p.join(tmp.resolveSymbolicLinksSync(), 'sdk');
    cacheRoot = p.join(tmp.resolveSymbolicLinksSync(), 'cache');
  });
  tearDown(() => tmp.delete(recursive: true));

  IosEngineCache engine(FlutterBuildMode mode) =>
      workspaceSdk(sdk, cacheRoot, 'sdk', mode: mode);

  Future<FlutterToolWorkspace> create(IosEngineCache cache) =>
      FlutterToolWorkspace.create(
        flutterRoot: cache.flutterRoot,
        engineCache: cache,
      );

  String workspaceEngine(FlutterToolWorkspace workspace, String name) => p.join(
    workspace.flutterRoot,
    'bin',
    'cache',
    'artifacts',
    'engine',
    name,
  );

  /// Every link under [root].
  List<String> links(String root) => [
    for (final entity in Directory(
      root,
    ).listSync(recursive: true, followLinks: false))
      if (entity is Link) p.relative(entity.path, from: root),
  ];

  group('without SDK iOS engine artifacts', () {
    test('gives every iOS engine directory a LICENSE and its own '
        'ios-sdk.stamp', () async {
      // Like a Linux or Windows SDK, or macOS before `precache --ios`: the
      // SDK's stamp claims iOS artifacts that are not there.
      File(p.join(sdk, 'bin', 'cache', 'ios-sdk.stamp'))
        ..createSync(recursive: true)
        ..writeAsStringSync('stale-engine');
      final cache = engine(FlutterBuildMode.release);
      Directory(cache.engineDirectory).createSync(recursive: true);
      File(
        p.join(cache.engineDirectory, 'gen_snapshot_arm64'),
      ).writeAsStringSync('gen_snapshot');
      final workspace = await create(cache);

      expectSelfContainedWorkspace(workspace, cache);
      for (final name in ['ios', 'ios-profile', 'ios-release']) {
        expect(
          File(
            p.join(workspaceEngine(workspace, name), 'LICENSE'),
          ).readAsStringSync(),
          'sdk',
        );
      }
      expect(
        File(
          p.join(
            workspaceEngine(workspace, 'ios-release'),
            'gen_snapshot_arm64',
          ),
        ).readAsStringSync(),
        'gen_snapshot',
      );
      expect(
        Directory(
          workspaceEngine(workspace, 'ios-profile'),
        ).listSync().map((entity) => p.basename(entity.path)),
        ['LICENSE'],
      );
      expect(
        File(p.join(sdk, 'bin', 'cache', 'ios-sdk.stamp')).readAsStringSync(),
        'stale-engine',
      );
    });

    test(
      'writes into the workspace never reach the SDK or engine cache',
      () async {
        final sdkCache = p.join(sdk, 'bin', 'cache');
        final cache = engine(FlutterBuildMode.debug);
        final sdkStamp = File(p.join(sdkCache, 'ios-sdk.stamp'))
          ..writeAsStringSync('sdk');
        final before = {
          for (final root in [sdk, cacheRoot])
            root: await nativeAssetTree(root),
        };
        final workspace = await create(cache);
        final created = await nativeAssetTree(cacheRoot);
        expectSelfContainedWorkspace(workspace, cache);

        // What flutter_tools writes when it refreshes its iOS artifacts.
        for (final name in ['ios', 'ios-profile', 'ios-release']) {
          File(
            p.join(workspaceEngine(workspace, name), 'LICENSE'),
          ).writeAsStringSync('refreshed');
        }
        for (final stamp in ['ios-sdk', 'engine', 'flutter_sdk']) {
          File(
            p.join(workspace.flutterRoot, 'bin', 'cache', '$stamp.stamp'),
          ).writeAsStringSync('refreshed');
        }
        File(
          p.join(workspace.flutterRoot, 'bin', 'cache', 'lockfile'),
        ).writeAsStringSync('locked');
        Directory(
          p.join(workspace.flutterRoot, 'bin', 'cache', 'downloads', 'ios'),
        ).createSync(recursive: true);

        expect(await nativeAssetTree(sdk), before[sdk]);
        expect(sdkStamp.readAsStringSync(), 'sdk');
        expect(
          File(p.join(sdkCache, 'flutter_tools.snapshot')).readAsStringSync(),
          'sdk',
        );
        final workspaceRoot = p.relative(
          workspace.flutterRoot,
          from: cacheRoot,
        );
        expect(
          [
            for (final entry in await nativeAssetTree(cacheRoot))
              if (!p.isWithin(workspaceRoot, entry) && entry != workspaceRoot)
                entry,
          ],
          [
            for (final entry in created)
              if (!p.isWithin(workspaceRoot, entry) && entry != workspaceRoot)
                entry,
          ],
        );
        for (final link in links(workspace.flutterRoot)) {
          expect(
            p.isWithin(
              workspace.flutterRoot,
              Link(
                p.join(workspace.flutterRoot, link),
              ).resolveSymbolicLinksSync(),
            ),
            isFalse,
            reason: 'links lead only to shared read-only entries: $link',
          );
        }
      },
      skip: Platform.isWindows,
    );

    test('copies a linked SDK cache file instead of linking it', () async {
      final real = Directory(p.join(tmp.path, 'real-sdk'))..createSync();
      final lockfile = File(p.join(real.path, 'lockfile'))
        ..writeAsStringSync('');
      final cache = engine(FlutterBuildMode.debug);
      Link(p.join(sdk, 'bin', 'cache', 'lockfile')).createSync(lockfile.path);
      final workspace = await create(cache);
      final copy = p.join(workspace.flutterRoot, 'bin', 'cache', 'lockfile');

      expect(
        FileSystemEntity.typeSync(copy, followLinks: false),
        FileSystemEntityType.file,
      );
      File(copy).writeAsStringSync('locked');
      expect(lockfile.readAsStringSync(), isEmpty);
    }, skip: Platform.isWindows);
  });

  group('per build mode', () {
    test('keeps one workspace per mode and reuses each', () async {
      final roots = <FlutterBuildMode, String>{};
      for (final mode in FlutterBuildMode.values) {
        final workspace = await create(engine(mode));
        File(
          p.join(workspace.flutterRoot, 'retained'),
        ).writeAsStringSync(mode.name);
        roots[mode] = workspace.flutterRoot;
      }
      expect(roots.values.toSet(), hasLength(FlutterBuildMode.values.length));

      for (final mode in [
        FlutterBuildMode.debug,
        FlutterBuildMode.release,
        FlutterBuildMode.debug,
      ]) {
        final workspace = await create(engine(mode));
        expect(workspace.flutterRoot, roots[mode]);
        expect(
          File(p.join(workspace.flutterRoot, 'retained')).readAsStringSync(),
          mode.name,
        );
      }
    });

    test('serves the mode engine in its directory', () async {
      final release = engine(FlutterBuildMode.release);
      final debug = engine(FlutterBuildMode.debug);
      final releaseWorkspace = await create(release);
      final debugWorkspace = await create(debug);

      expect(
        await Directory(
          p.join(
            workspaceEngine(releaseWorkspace, 'ios-release'),
            'Flutter.xcframework',
          ),
        ).resolveSymbolicLinks(),
        await Directory(release.flutterXcframework).resolveSymbolicLinks(),
      );
      expect(
        Directory(
          p.join(
            workspaceEngine(debugWorkspace, 'ios-release'),
            'Flutter.xcframework',
          ),
        ).existsSync(),
        isFalse,
      );
      expect(
        await Directory(
          p.join(workspaceEngine(debugWorkspace, 'ios'), 'Flutter.xcframework'),
        ).resolveSymbolicLinks(),
        await Directory(debug.flutterXcframework).resolveSymbolicLinks(),
      );
    });
  });

  group('readiness', () {
    Future<void> expectRebuilt(
      void Function(FlutterToolWorkspace workspace) damage, {
      required void Function(FlutterToolWorkspace workspace) repaired,
    }) async {
      final cache = engine(FlutterBuildMode.release);
      final first = await create(cache);
      final sentinel = File(p.join(first.flutterRoot, 'retained'))
        ..writeAsStringSync('retained');
      damage(first);
      final second = await create(cache);

      expect(second.flutterRoot, first.flutterRoot);
      expect(sentinel.existsSync(), isFalse, reason: 'workspace was reused');
      expectSelfContainedWorkspace(second, cache);
      repaired(second);
    }

    test('rebuilds an engine directory replaced by a write-through link', () {
      final shared = Directory(p.join(tmp.path, 'shared-ios-profile'))
        ..createSync();
      return expectRebuilt(
        (workspace) {
          final directory = workspaceEngine(workspace, 'ios-profile');
          Directory(directory).deleteSync(recursive: true);
          Link(directory).createSync(shared.path);
        },
        repaired: (workspace) {
          expect(shared.listSync(), isEmpty);
        },
      );
    }, skip: Platform.isWindows);

    test('rebuilds a stamp rewritten by flutter_tools', () {
      return expectRebuilt(
        (workspace) => File(
          p.join(workspace.flutterRoot, 'bin', 'cache', 'ios-sdk.stamp'),
        ).writeAsStringSync('other-engine'),
        repaired: (workspace) {},
      );
    });

    test('rebuilds an engine directory with stray downloads', () {
      return expectRebuilt(
        (workspace) => Directory(
          p.join(
            workspaceEngine(workspace, 'ios-profile'),
            'Flutter.xcframework',
          ),
        ).createSync(),
        repaired: (workspace) => expect(
          Directory(
            p.join(
              workspaceEngine(workspace, 'ios-profile'),
              'Flutter.xcframework',
            ),
          ).existsSync(),
          isFalse,
        ),
      );
    });

    test('rebuilds a partial workspace', () {
      return expectRebuilt(
        (workspace) => Directory(
          workspaceEngine(workspace, 'common'),
        ).deleteSync(recursive: true),
        repaired: (workspace) {},
      );
    });

    test('reuses an intact workspace', () async {
      final cache = engine(FlutterBuildMode.release);
      final first = await create(cache);
      final sentinel = File(p.join(first.flutterRoot, 'retained'))
        ..writeAsStringSync('retained');
      final second = await create(cache);
      expect(second.flutterRoot, first.flutterRoot);
      expect(sentinel.readAsStringSync(), 'retained');
    });
  });
}
