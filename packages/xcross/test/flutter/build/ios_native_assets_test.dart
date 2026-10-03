import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/apple_tool_shim_templates.dart';
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/flutter/build/internal/flutter_tool_workspace.dart';
import 'package:xcross/src/flutter/build/internal/native_asset_frameworks.dart';
import 'package:xcross/src/flutter/build/internal/native_assets_hook_discovery.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/flutter/build/ios_native_assets.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/host/linux/flutter/native_host_tools.dart';
import 'package:xcross/src/host/macos/flutter/native_host_tools.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer_posix.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';
import 'package:xcross/src/host/windows/flutter/apple_tool_shim_renderer.dart';
import 'package:xcross/src/host/windows/flutter/native_host_tools.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';
import 'package:xcross/src/target/simulator/flutter/simulator_flutter_target.dart';

void main() {
  test('native hook assembly preserves target, manifest and flavor inputs', () {
    final host = LinuxHost(architecture: 'arm64');
    final runner = ProcessRunner(host);
    final hostTools = LinuxNativeHostTools(host, runner);
    final target = SimulatorTarget(host);
    final cache = IosEngineCache(
      targetPolicy: SimulatorFlutterTarget(target),
      hostTools: hostTools,
      flutterRoot: '/flutter',
    );
    final builder = IosNativeAssetsBuilder(
      engineCache: cache,
      renderer: PosixAppleToolShimRenderer(host),
      runner: runner,
      tools: AppleToolShimResolver(
        target,
        runner,
        DarwinSdkRepository(host),
        DarwinToolchainResolver(runner, LinuxDarwinToolchainLocations(host)),
        hostTools: hostTools,
        executable: '/xcross',
      ),
      projectRoot: '/project',
      flutterRoot: '/flutter',
      deploymentTarget: const IosDeploymentTarget(
        '15.0',
        platform: SimulatorBuildPlatform(),
      ),
      entrypoint: 'lib/flavored.dart',
      dartDefines: const ['CUSTOM=value'],
      flavor: 'development',
    );
    final arguments = builder.assembleArguments(
      output: '/output',
      iosSdk: '/simulator-sdk',
    );
    expect(
      arguments,
      containsAll([
        '-dTargetPlatform=ios',
        '-dBuildMode=debug',
        '-dIosArchs=arm64',
        '-dSdkRoot=/simulator-sdk',
        '-dTargetFile=lib/flavored.dart',
        '-dIosDeploymentTarget=15.0',
        'debug_ios_bundle_flutter_assets',
      ]),
    );
    final defines = arguments
        .singleWhere((arg) => arg.startsWith('-dDartDefines='))
        .substring('-dDartDefines='.length)
        .split(',')
        .map((value) => utf8.decode(base64.decode(value)));
    expect(
      defines,
      containsAll(['CUSTOM=value', 'FLUTTER_APP_FLAVOR=development']),
    );
    expect(
      builder.assembleArguments(output: '/bundle').last,
      'copy_flutter_bundle',
    );
    expect(
      cache.targetPolicy.buildDirectory('/project', 'xcross-native-assets'),
      p.join(
        '/project',
        'build',
        'xcross-ios-simulator',
        'xcross-native-assets',
      ),
    );
  });

  test(
    'Windows simulator sidecars preserve SDK and explicit linker platform',
    () async {
      final tmp = await Directory.systemTemp.createTemp('simulator-sidecars-');
      addTearDown(() => tmp.delete(recursive: true));
      final forwarder = File(p.join(tmp.path, 'xcross.exe'))
        ..writeAsStringSync('forwarder');
      final xcrun = File(p.join(tmp.path, 'source-xcrun.exe'))
        ..writeAsStringSync('bundled-xcrun');
      final directory = p.join(tmp.path, 'shims with spaces');
      await installAppleToolShims(
        directory,
        AppleToolShimConfig(
          target: const SimulatorBuildPlatform(),
          iosSdk: r'C:\SDK\iPhoneSimulator.sdk',
          clang: r'C:\LLVM\clang.exe',
          hostCompiler: r'C:\LLVM\clang.exe',
          archiver: r'C:\LLVM\llvm-ar.exe',
          linker: r'C:\LLVM\ld64.lld.exe',
          lipo: r'C:\LLVM\llvm-lipo.exe',
          otool: null,
          installNameTool: null,
          xcrun: xcrun.path,
          deploymentTarget: '15.0',
        ),
        renderer: WindowsAppleToolShimRenderer(_windowsHost()),
        toolForwarderExecutable: forwarder.path,
      );
      final flags = jsonDecode(
        File(p.join(directory, 'clang.exe.args')).readAsStringSync(),
      );
      expect(
        flags,
        containsAll([
          '--target=arm64-apple-ios15.0-simulator',
          '-mios-simulator-version-min=15.0',
          '-Wl,-arch,arm64',
          '-Wl,-platform_version,ios-simulator,15.0,26.5',
          '-fuse-ld=lld',
        ]),
      );
      expect(
        File(p.join(directory, 'xcrun.exe')).readAsStringSync(),
        'bundled-xcrun',
      );
      expect(
        File(p.join(directory, 'xcrun.exe.sdk')).readAsStringSync(),
        r'C:\SDK\iPhoneSimulator.sdk',
      );
      expect(
        File(p.join(directory, 'cc.exe.args')).readAsStringSync(),
        File(p.join(directory, 'clang.exe.args')).readAsStringSync(),
      );
    },
  );

  test(
    'macOS tool resolution retains bundled xcross xcrun delegation',
    () async {
      final tmp = await Directory.systemTemp.createTemp('macos-bundled-xcrun-');
      addTearDown(() => tmp.delete(recursive: true));
      final launcher = File(p.join(tmp.path, 'xcross'))..writeAsStringSync('');
      final sibling = File(p.join(tmp.path, 'xcrun'))
        ..writeAsStringSync('bundled');
      final host = MacOSHost(architecture: 'arm64');
      final runner = ProcessRunner(host);
      final resolver = AppleToolShimResolver(
        IPhoneTarget(host),
        runner,
        DarwinSdkRepository(host),
        DarwinToolchainResolver(runner, MacOSDarwinToolchainLocations(host)),
        hostTools: MacOSNativeHostTools(host, runner),
        executable: '/dart',
        launcher: launcher.path,
        declarative: true,
      );
      expect(await resolver.resolveXcrun(), sibling.path);
      expect((await resolver.resolveHostCompiler('/cross/clang')).arguments, [
        '--sdk',
        'macosx',
        'clang',
      ]);
    },
  );

  test(
    'simulator compiler shim preserves explicit simulator deployment and host work',
    () async {
      if (Platform.isWindows) return;
      final temp = await Directory.systemTemp.createTemp(
        'simulator-compiler-shim-',
      );
      try {
        final shim = File(p.join(temp.path, 'clang'));
        await shim.writeAsString(
          renderUnixCompilerShim(
            iosSdk: '/simulator-sdk',
            clang: '/bin/echo',
            hostCompiler: '/bin/echo',
            linker: '/ld64.lld',
            deploymentTarget: '15.0',
            target: const SimulatorBuildPlatform(),
          ),
        );
        final simulator = await Process.run('/bin/sh', [
          shim.path,
          '-arch',
          'arm64',
          '-c',
          'probe.c',
        ]);
        expect(simulator.exitCode, 0);
        expect(
          simulator.stdout,
          contains('--target=arm64-apple-ios15.0-simulator'),
        );
        expect(simulator.stdout, contains('-mios-simulator-version-min=15.0'));
        expect(simulator.stdout, isNot(contains('-miphoneos-version-min')));
        final explicit = await Process.run('/bin/sh', [
          shim.path,
          '-target',
          'arm64-apple-ios16.0-simulator',
          '-mios-simulator-version-min=16.0',
          '-c',
          'probe.c',
        ]);
        expect(explicit.stdout, contains('-mios-simulator-version-min=16.0'));
        expect(explicit.stdout, isNot(contains('-version-min=15.0')));
        final host = await Process.run('/bin/sh', [shim.path, '-c', 'host.c']);
        expect(host.stdout.toString().trim(), '-c host.c');
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'isolates host workspaces and exposes canonical Flutter cache paths',
    () async {
      final tmp = await Directory.systemTemp.createTemp(
        'flutter_workspace_hosts-',
      );
      try {
        final roots = <String>{};
        final iosFrameworks = <String>{};
        final flutterRoot = p.join(tmp.path, 'sdk');
        Directory(p.join(flutterRoot, 'packages')).createSync(recursive: true);
        final sdkCache = Directory(p.join(flutterRoot, 'bin', 'cache'))
          ..createSync(recursive: true);
        File(p.join(flutterRoot, 'bin', 'internal', 'engine.version'))
          ..createSync(recursive: true)
          ..writeAsStringSync('engine-hash');
        Directory(p.join(sdkCache.path, 'dart-sdk')).createSync();
        File(
          p.join(sdkCache.path, 'flutter_tools.snapshot'),
        ).writeAsStringSync('snapshot');
        for (final (abi, hostTools, targetPolicy) in _hostCases()) {
          final cache = IosEngineCache(
            targetPolicy: targetPolicy,
            hostTools: hostTools,
            flutterRoot: flutterRoot,
            cacheRoot: p.join(tmp.path, 'cache'),
          );
          Directory(cache.flutterXcframework).createSync(recursive: true);
          iosFrameworks.add(cache.flutterXcframework);
          Directory(cache.patchedSdkRoot).createSync(recursive: true);
          File(cache.vmSnapshotData)
            ..createSync(recursive: true)
            ..writeAsStringSync(abi);
          File(cache.isolateSnapshotData).writeAsStringSync(abi);
          final workspace = await FlutterToolWorkspace.create(
            flutterRoot: flutterRoot,
            engineCache: cache,
          );
          roots.add(workspace.flutterRoot);
          expect(workspace.dart, startsWith(flutterRoot));
          expect(workspace.flutterToolsSnapshot, startsWith(flutterRoot));
          final engine = p.join(
            workspace.flutterRoot,
            'bin',
            'cache',
            'artifacts',
            'engine',
          );
          expect(
            File(
              p.join(
                engine,
                cache.hostEngineCacheDirectory,
                'vm_isolate_snapshot.bin',
              ),
            ).readAsStringSync(),
            abi,
          );
          expect(
            Directory(
              p.join(engine, 'ios', 'Flutter.xcframework'),
            ).existsSync(),
            isTrue,
          );
          if (cache.hostArtifactPlatform == 'darwin-arm64') {
            expect(
              Directory(p.join(engine, 'darwin-arm64')).existsSync(),
              isFalse,
            );
          }
        }
        expect(roots, hasLength(5));
        expect(iosFrameworks, hasLength(1));
      } finally {
        await tmp.delete(recursive: true);
      }
    },
  );

  for (final removeOldRoot in [false, true]) {
    test(
      'isolates same-engine SDK roots with old root removed: $removeOldRoot',
      () async {
        final tmp = await Directory.systemTemp.createTemp('workspace_sources-');
        try {
          final cacheRoot = p.join(tmp.path, 'cache');
          final firstCache = _workspaceSdk(
            p.join(tmp.path, 'sdk-a'),
            cacheRoot,
            'sdk-a',
          );
          final secondCache = _workspaceSdk(
            p.join(tmp.path, 'sdk-b'),
            cacheRoot,
            'sdk-b',
          );
          final first = await FlutterToolWorkspace.create(
            flutterRoot: firstCache.flutterRoot,
            engineCache: firstCache,
          );
          if (removeOldRoot) {
            await Directory(firstCache.flutterRoot).delete(recursive: true);
          }
          final second = await FlutterToolWorkspace.create(
            flutterRoot: secondCache.flutterRoot,
            engineCache: secondCache,
          );

          _expectWorkspaceSdk(second, 'sdk-b');
          expect(second.flutterRoot, isNot(first.flutterRoot));
          expect(Directory(first.flutterRoot).existsSync(), isTrue);
          expect(second.dart, startsWith(secondCache.flutterRoot));
          expect(
            second.flutterToolsSnapshot,
            startsWith(secondCache.flutterRoot),
          );
        } finally {
          await tmp.delete(recursive: true);
        }
      },
    );
  }

  test(
    'reuses a canonical SDK root through relative paths and aliases',
    () async {
      if (Platform.isWindows) return;
      final tmp = await Directory.systemTemp.createTemp('workspace_alias-');
      try {
        final cache = _workspaceSdk(
          p.join(tmp.path, 'sdk'),
          p.join(tmp.path, 'cache'),
          'sdk',
        );
        final first = await FlutterToolWorkspace.create(
          flutterRoot: p.relative(cache.flutterRoot),
          engineCache: cache,
        );
        final sentinel = File(p.join(first.flutterRoot, 'retained'))
          ..writeAsStringSync('retained');
        final alias = Link(p.join(tmp.path, 'alias'))
          ..createSync(cache.flutterRoot);
        final second = await FlutterToolWorkspace.create(
          flutterRoot: alias.path,
          engineCache: IosEngineCache(
            targetPolicy: IPhoneFlutterTarget(IPhoneTarget(_linuxHost)),
            hostTools: LinuxNativeHostTools(
              _linuxHost,
              ProcessRunner(_linuxHost),
            ),
            flutterRoot: alias.path,
            cacheRoot: cache.cacheRoot,
          ),
        );

        expect(second.flutterRoot, first.flutterRoot);
        expect(sentinel.readAsStringSync(), 'retained');
        _expectWorkspaceSdk(second, 'sdk');
      } finally {
        await tmp.delete(recursive: true);
      }
    },
  );

  test(
    'pins SDK-local engine artifacts and tools across alias changes',
    () async {
      if (Platform.isWindows) return;
      final tmp = await Directory.systemTemp.createTemp(
        'workspace_local_alias-',
      );
      try {
        final cacheRoot = p.join(tmp.path, 'cache');
        final firstCache = _workspaceSdk(
          p.join(tmp.path, 'sdk-a'),
          cacheRoot,
          'sdk-a',
          sdkLocalEngine: true,
        );
        final secondCache = _workspaceSdk(
          p.join(tmp.path, 'sdk-b'),
          cacheRoot,
          'sdk-b',
          sdkLocalEngine: true,
        );
        final alias = Link(p.join(tmp.path, 'alias'))
          ..createSync(firstCache.flutterRoot);
        final workspace = await FlutterToolWorkspace.create(
          flutterRoot: alias.path,
          engineCache: IosEngineCache(
            targetPolicy: IPhoneFlutterTarget(IPhoneTarget(_linuxHost)),
            hostTools: LinuxNativeHostTools(
              _linuxHost,
              ProcessRunner(_linuxHost),
            ),
            flutterRoot: alias.path,
            cacheRoot: cacheRoot,
          ),
        );
        final sentinel = File(p.join(workspace.flutterRoot, 'retained'))
          ..writeAsStringSync('retained');
        final engine = p.join(
          workspace.flutterRoot,
          'bin',
          'cache',
          'artifacts',
          'engine',
        );
        void expectFirstSdk() {
          _expectWorkspaceSdk(workspace, 'sdk-a');
          expect(
            File(workspace.flutterToolsSnapshot).readAsStringSync(),
            'sdk-a',
          );
          expect(File(workspace.dart).readAsStringSync(), 'sdk-a');
          for (final relative in [
            p.join('ios', 'Flutter.xcframework', 'source'),
            p.join('linux-arm64', 'vm_isolate_snapshot.bin'),
            p.join('common', 'flutter_patched_sdk', 'source'),
          ]) {
            expect(File(p.join(engine, relative)).readAsStringSync(), 'sdk-a');
          }
        }

        expectFirstSdk();
        await alias.delete();
        await alias.create(secondCache.flutterRoot);
        expectFirstSdk();
        await alias.delete();
        expectFirstSdk();

        final reused = await FlutterToolWorkspace.create(
          flutterRoot: firstCache.flutterRoot,
          engineCache: firstCache,
        );
        expect(reused.flutterRoot, workspace.flutterRoot);
        expect(sentinel.readAsStringSync(), 'retained');
        expectFirstSdk();
      } finally {
        await tmp.delete(recursive: true);
      }
    },
  );

  test(
    'launches relative SDK tools from a different project directory',
    () async {
      if (Platform.isWindows) return;
      final tmp = await Directory.systemTemp.createTemp(
        'workspace_launch_cwd-',
      );
      try {
        final cache = _workspaceSdk(
          p.join(tmp.path, 'sdk'),
          p.join(tmp.path, 'cache'),
          'sdk',
        );
        final dart =
            File(
                p.join(
                  cache.flutterRoot,
                  'bin',
                  'cache',
                  'dart-sdk',
                  'bin',
                  'dart',
                ),
              )
              ..createSync(recursive: true)
              ..writeAsStringSync('#!/bin/sh\ncat "\$1"\n');
        final chmod = await Process.run('/bin/chmod', ['+x', dart.path]);
        expect(chmod.exitCode, 0);
        final project = Directory(p.join(tmp.path, 'project'))..createSync();
        final relativeRoot = p.relative(cache.flutterRoot);
        final first = await FlutterToolWorkspace.create(
          flutterRoot: relativeRoot,
          engineCache: cache,
        );
        final second = await FlutterToolWorkspace.create(
          flutterRoot: relativeRoot,
          engineCache: cache,
        );
        for (final workspace in [first, second]) {
          expect(p.isAbsolute(workspace.dart), isTrue);
          expect(p.isAbsolute(workspace.flutterToolsSnapshot), isTrue);
          final result = await Process.run(workspace.dart, [
            workspace.flutterToolsSnapshot,
          ], workingDirectory: project.path);
          expect(result.exitCode, 0, reason: '${result.stderr}');
          expect(result.stdout, 'sdk');
        }
      } finally {
        await tmp.delete(recursive: true);
      }
    },
  );

  test('migrates legacy ready overlays before aliases change', () async {
    if (Platform.isWindows) return;
    final tmp = await Directory.systemTemp.createTemp(
      'workspace_legacy_ready-',
    );
    try {
      final cacheRoot = p.join(tmp.path, 'cache');
      final firstCache = _workspaceSdk(
        p.join(tmp.path, 'sdk-a'),
        cacheRoot,
        'sdk-a',
        sdkLocalEngine: true,
      );
      final secondCache = _workspaceSdk(
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
      final aliasCache = IosEngineCache(
        targetPolicy: IPhoneFlutterTarget(IPhoneTarget(_linuxHost)),
        hostTools: LinuxNativeHostTools(_linuxHost, ProcessRunner(_linuxHost)),
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
        final link = Link(p.join(engine, name));
        await link.delete();
        await link.create(
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
      expect(marker.readAsStringSync(), 'ready-v2\n');
      expect(untouched.readAsStringSync(), 'keep');
      for (final name in ['ios', 'linux-arm64', 'common']) {
        expect(
          await Link(p.join(engine, name)).target(),
          await Directory(
            p.join(
              firstCache.flutterRoot,
              'bin',
              'cache',
              'artifacts',
              'engine',
              name,
            ),
          ).resolveSymbolicLinks(),
        );
      }
      for (final removeAlias in [false, true]) {
        await alias.delete();
        if (!removeAlias) await alias.create(secondCache.flutterRoot);
        _expectWorkspaceSdk(migrated, 'sdk-a');
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
    (p.join('bin', 'cache', 'artifacts', 'fonts'), false),
    (p.join('bin', 'cache', 'artifacts', 'engine', 'linux-arm64'), false),
    (p.join('bin', 'cache', 'artifacts', 'engine', 'ios'), false),
    (p.join('bin', 'cache', 'artifacts', 'engine', 'common'), false),
    (p.join('bin', 'cache', 'flutter_tools.snapshot'), false),
    (p.join('bin', 'internal', 'engine.version'), false),
  ]) {
    test(
      'repairs a ready workspace with stale $staleEntry dangling: $dangling',
      () async {
        if (Platform.isWindows) return;
        final tmp = await Directory.systemTemp.createTemp('workspace_stale-');
        try {
          final cache = _workspaceSdk(
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
          _expectWorkspaceSdk(second, 'sdk');
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
            await Directory(p.join(engine, 'ios')).resolveSymbolicLinks(),
            await Directory(
              p.dirname(cache.flutterXcframework),
            ).resolveSymbolicLinks(),
          );
          expect(
            await Directory(p.join(engine, 'common')).resolveSymbolicLinks(),
            await Directory(
              p.dirname(cache.patchedSdkRoot),
            ).resolveSymbolicLinks(),
          );
        } finally {
          await tmp.delete(recursive: true);
        }
      },
    );
  }

  test('isolates engine versions at the same SDK root', () async {
    final tmp = await Directory.systemTemp.createTemp('workspace_engines-');
    try {
      final cache = _workspaceSdk(
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
        final engineCache = IosEngineCache(
          targetPolicy: IPhoneFlutterTarget(IPhoneTarget(_linuxHost)),
          hostTools: LinuxNativeHostTools(
            _linuxHost,
            ProcessRunner(_linuxHost),
          ),
          flutterRoot: flutterRoot,
          cacheRoot: cacheRoot,
        );
        Directory(engineCache.flutterXcframework).createSync(recursive: true);
        final before = await _tree(flutterRoot);

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
        expect(await _tree(flutterRoot), before);
      } finally {
        await tmp.delete(recursive: true);
      }
    },
  );

  test('reuses one workspace path across builds', () async {
    // `flutter assemble` records the absolute path of every input it read in
    // its dependency stamps, and this workspace supplies the Dart SDK and
    // engine artifacts it reads. A path that changes per build therefore
    // guarantees a stale stamp on the next run, and Flutter re-runs the whole
    // native-assets pipeline, build hooks included, every time.
    // Unlike the overlay test above, this asserts only on the chosen path, so
    // it runs on Windows too: the per-build path bug this guards was a Windows
    // build-time regression.
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
      final engineCache = IosEngineCache(
        targetPolicy: IPhoneFlutterTarget(IPhoneTarget(_linuxHost)),
        hostTools: LinuxNativeHostTools(_linuxHost, ProcessRunner(_linuxHost)),
        flutterRoot: flutterRoot,
        cacheRoot: p.join(tmp.path, 'cache'),
      );
      Directory(engineCache.flutterXcframework).createSync(recursive: true);
      // The workspace links the host vm-snapshot and patched-SDK directories
      // too, and on Windows linking a missing target fails outright.
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

  test('detects build hooks through package_config root URIs', () async {
    final tmp = await Directory.systemTemp.createTemp('hook_detection_test-');
    try {
      final package = Directory(p.join(tmp.path, 'dependency'))..createSync();
      Directory(p.join(package.path, 'hook')).createSync();
      File(p.join(package.path, 'hook', 'build.dart')).writeAsStringSync('');
      final dartTool = Directory(p.join(tmp.path, 'app', '.dart_tool'))
        ..createSync(recursive: true);
      File(p.join(dartTool.path, 'package_config.json')).writeAsStringSync('''
{"configVersion":2,"packages":[{"name":"dependency","rootUri":"../../dependency","packageUri":"lib/"}]}
''');

      expect(await hasNativeAssetsBuildHooks(p.join(tmp.path, 'app')), isTrue);
      File(p.join(package.path, 'hook', 'build.dart')).deleteSync();
      expect(await hasNativeAssetsBuildHooks(p.join(tmp.path, 'app')), isFalse);
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('reports malformed package config clearly', () async {
    final tmp = await Directory.systemTemp.createTemp('hook_detection_test-');
    try {
      final dartTool = Directory(p.join(tmp.path, '.dart_tool'))
        ..createSync(recursive: true);
      File(p.join(dartTool.path, 'package_config.json')).writeAsStringSync('{');

      await expectLater(
        hasNativeAssetsBuildHooks(tmp.path),
        throwsA(
          isA<FlutterBuildError>().having(
            (error) => error.message,
            'message',
            contains('malformed JSON'),
          ),
        ),
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('detects native hooks from an ancestor workspace config', () async {
    final tmp = await Directory.systemTemp.createTemp('workspace_hooks-');
    try {
      final app = Directory(p.join(tmp.path, 'apps', 'example'))
        ..createSync(recursive: true);
      final hook = File(
        p.join(tmp.path, 'dependency with spaces', 'hook', 'build.dart'),
      )..createSync(recursive: true);
      final config = File(p.join(tmp.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true);
      config.writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'native_dependency',
              'rootUri': '../dependency%20with%20spaces/',
              'packageUri': 'lib/',
            },
          ],
        }),
      );

      expect(await hasNativeAssetsBuildHooks(app.path), isTrue);
      hook.deleteSync();
      expect(await hasNativeAssetsBuildHooks(app.path), isFalse);

      // A local config takes precedence over the ancestor's hook packages.
      hook.createSync();
      File(p.join(app.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"configVersion":2,"packages":[]}');
      expect(await hasNativeAssetsBuildHooks(app.path), isFalse);
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('normalizes native asset framework install names', () async {
    final tmp = await Directory.systemTemp.createTemp('native_framework_test-');
    try {
      final asset = Directory(p.join(tmp.path, 'Asset.framework'))
        ..createSync();
      final dependency = Directory(p.join(tmp.path, 'Dependency.framework'))
        ..createSync();
      final assetBytes = _dylibMachO([
        '/very/long/native/assets/path/libAsset.dylib',
        '/very/long/native/assets/path/libDependency.dylib',
      ]);
      final dependencyBytes = _dylibMachO([
        '/very/long/native/assets/path/libDependency.dylib',
      ]);

      File(p.join(asset.path, 'Asset')).writeAsBytesSync(assetBytes);
      File(
        p.join(dependency.path, 'Dependency'),
      ).writeAsBytesSync(dependencyBytes);

      await normalizeNativeAssetInstallNames([asset.path, dependency.path]);

      expect(_dylibNames(File(p.join(asset.path, 'Asset')).readAsBytesSync()), [
        '@rpath/Asset.framework/Asset',
        '@rpath/Dependency.framework/Dependency',
      ]);
      expect(
        _dylibNames(
          File(p.join(dependency.path, 'Dependency')).readAsBytesSync(),
        ),
        ['@rpath/Dependency.framework/Dependency'],
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('detects all FAT Mach-O binaries', () async {
    final tmp = await Directory.systemTemp.createTemp('fat_macho_test-');
    try {
      for (final magic in const <List<int>>[
        [0xca, 0xfe, 0xba, 0xbe],
        [0xbe, 0xba, 0xfe, 0xca],
        [0xca, 0xfe, 0xba, 0xbf],
        [0xbf, 0xba, 0xfe, 0xca],
      ]) {
        final fat = File(p.join(tmp.path, 'fat-${magic.first}'))
          ..writeAsBytesSync(magic);
        expect(await isFatMachO(fat.path), isTrue);
      }
      final thin = File(p.join(tmp.path, 'thin'))
        ..writeAsBytesSync([0xcf, 0xfa, 0xed, 0xfe]);
      expect(await isFatMachO(thin.path), isFalse);
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('falls back from llvm-otool to llvm-objdump', () async {
    final requested = <String>[];
    final result = await resolveOtool(
      find: (name) async {
        requested.add(name);
        return name == 'llvm-objdump' ? '/llvm/llvm-objdump' : null;
      },
    );

    expect(requested, ['llvm-otool', 'llvm-objdump']);
    expect(result?.executable, '/llvm/llvm-objdump');
    expect(result?.usesObjdump, isTrue);
  });

  test('translates otool options for llvm-objdump', () {
    final unix = renderUnixOtoolShim(tool: '/llvm/objdump', usesObjdump: true);
    final windows = renderPowerShellOtoolShim(
      tool: r'C:\LLVM\llvm-objdump.exe',
      usesObjdump: true,
    );

    for (final translation in [
      '--macho --dylibs-used',
      '--macho --dylib-id',
      '--macho --private-headers',
    ]) {
      expect(unix, contains(translation));
    }
    for (final translation in [
      "@('--macho', '--dylibs-used')",
      "@('--macho', '--dylib-id')",
      "@('--macho', '--private-headers')",
    ]) {
      expect(windows, contains(translation));
    }
  });

  test('Windows uses the resolved clang as its host C compiler', () async {
    final host = _windowsHost();
    final compiler = await WindowsNativeHostTools(
      host,
      ProcessRunner(host),
    ).compiler(r'C:\Program Files\LLVM\bin\clang.exe');
    expect(compiler.executable, r'C:\Program Files\LLVM\bin\clang.exe');
    expect(compiler.arguments, isEmpty);
  });
  test('macOS host compiler selects macosx despite SDKROOT', () async {
    final host = MacOSHost(
      architecture: 'arm64',
      environment: const {'SDKROOT': '/ios/sdk'},
    );
    final compiler = await MacOSNativeHostTools(
      host,
      ProcessRunner(host),
    ).compiler('/cross/clang');
    expect(compiler.executable, '/usr/bin/xcrun');
    expect(compiler.arguments, ['--sdk', 'macosx', 'clang']);
  });
  test(
    'Linux host compiler retains configured cc without Apple arguments',
    () async {
      final host = LinuxHost(architecture: 'arm64');
      final runner = ProcessRunner(
        host,
        configuration: ProcessConfiguration(
          normalizedTools: const {'cc': '/host/cc'},
          effectiveChildEnvironment: const {},
        ),
      );
      final compiler = await LinuxNativeHostTools(
        host,
        runner,
      ).compiler('/cross/clang');
      expect(compiler.executable, '/host/cc');
      expect(compiler.arguments, isEmpty);
    },
  );

  test('Unix host compiler prefix arguments are shell quoted', () async {
    final temp = await Directory.systemTemp.createTemp('host-prefix-shim-');
    addTearDown(() => temp.delete(recursive: true));
    final shim = File(p.join(temp.path, 'clang'))
      ..writeAsStringSync(
        renderUnixCompilerShim(
          target: const IPhoneBuildPlatform(),
          iosSdk: '/simulator-sdk',
          clang: '/cross/clang',
          hostCompiler: '/usr/bin/printf',
          hostCompilerArguments: ['<%s>', "prefix with spaces and 'quotes'"],
          linker: '/ld64.lld',
          deploymentTarget: '15.0',
        ),
      );
    final result = await Process.run('/bin/sh', [shim.path, '-c', 'host.c']);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stdout, "<prefix with spaces and 'quotes'><-c><host.c>");
  }, skip: Platform.isWindows);

  test(
    'macOS installed compiler shim builds native host with Xcode-first PATH',
    () async {
      final temp = await Directory.systemTemp.createTemp('macos-host-shim-');
      addTearDown(() => temp.delete(recursive: true));
      final selection = await Process.run('/usr/bin/xcode-select', ['-p']);
      expect(selection.exitCode, 0, reason: selection.stderr.toString());
      final developer = Link(p.join(temp.path, 'chosen developer'))
        ..createSync(selection.stdout.toString().trim());
      final environment = Map<String, String>.of(Platform.environment)
        ..remove('SDKROOT')
        ..['DEVELOPER_DIR'] = developer.path;
      final native = await Process.run(
        '/usr/bin/xcrun',
        ['--sdk', 'macosx', '--find', 'clang'],
        environment: environment,
        includeParentEnvironment: false,
      );
      expect(native.exitCode, 0, reason: native.stderr.toString());
      final iosSdk = await Process.run(
        '/usr/bin/xcrun',
        ['--sdk', 'iphonesimulator', '--show-sdk-path'],
        environment: environment,
        includeParentEnvironment: false,
      );
      expect(iosSdk.exitCode, 0, reason: iosSdk.stderr.toString());
      environment['PATH'] =
          '${p.dirname(native.stdout.toString().trim())}:/usr/bin:/bin';
      final compiler = await MacOSNativeHostTools(
        MacOSHost(architecture: 'arm64'),
        ProcessRunner(MacOSHost(architecture: 'arm64')),
      ).compiler('/cross/clang');
      final shims = p.join(temp.path, 'shims');
      await installAppleToolShims(
        shims,
        AppleToolShimConfig(
          iosSdk: '/cross/iPhoneSimulator.sdk',
          clang: '/cross/clang',
          hostCompiler: compiler.executable,
          hostCompilerArguments: compiler.arguments,
          archiver: '/cross/ar',
          linker: '/cross/ld',
          lipo: '/cross/lipo',
          otool: null,
          installNameTool: null,
          xcrun: '/usr/bin/xcrun',
          deploymentTarget: '15.0',
          target: const SimulatorBuildPlatform(),
        ),
        renderer: PosixAppleToolShimRenderer(_linuxHost),
      );
      final source = File(p.join(temp.path, 'host.c'))
        ..writeAsStringSync(
          '#include <stdio.h>\nint main(void) { puts("native host"); return 0; }\n',
        );
      for (final sdkRoot in <String?>[null, iosSdk.stdout.toString().trim()]) {
        final executable = p.join(
          temp.path,
          sdkRoot == null ? 'clean-host' : 'polluted-host',
        );
        final result = await Process.run(
          p.join(shims, 'cc'),
          [source.path, '-o', executable],
          environment: {
            ...environment,
            if (sdkRoot != null) 'SDKROOT': sdkRoot,
          },
          includeParentEnvironment: false,
        );
        expect(result.exitCode, 0, reason: result.stderr.toString());
        final header = ByteData.sublistView(File(executable).readAsBytesSync());
        expect(header.getUint32(0, Endian.little), 0xfeedfacf);
        expect(
          header.getUint32(4, Endian.little),
          Abi.current() == Abi.macosArm64 ? 0x0100000c : 0x01000007,
        );
        final loadCommands = await Process.run(
          '/usr/bin/xcrun',
          ['--sdk', 'macosx', 'otool', '-l', executable],
          environment: environment,
          includeParentEnvironment: false,
        );
        expect(
          loadCommands.exitCode,
          0,
          reason: loadCommands.stderr.toString(),
        );
        expect(
          loadCommands.stdout,
          contains(RegExp(r'platform\s+(?:MACOS|1)(?:\s|$)')),
        );
        final run = await Process.run(executable, []);
        expect(run.exitCode, 0, reason: run.stderr.toString());
        expect(run.stdout, 'native host\n');
      }
    },
    skip:
        !Platform.isMacOS ||
        Platform.environment['XCROSS_NATIVE_COMPILER_ACCEPTANCE'] != '1',
  );

  test('Windows resolves native forwarders and configured launchers', () async {
    final tmp = await Directory.systemTemp.createTemp('native-forwarder-');
    addTearDown(() => tmp.delete(recursive: true));
    final launcher = File(p.join(tmp.path, 'xcross.exe'))
      ..writeAsStringSync('');
    final host = _windowsHost();
    final runner = ProcessRunner(
      host,
      configuration: ProcessConfiguration(
        normalizedTools: {'xcross': launcher.path},
        effectiveChildEnvironment: const {},
      ),
    );
    final tools = WindowsNativeHostTools(host, runner);
    expect(
      await tools.forwarder(r'C:\bundle\xcross.exe', null),
      r'C:\bundle\xcross.exe',
    );
    expect(await tools.forwarder('/dart', launcher.path), launcher.path);
    expect(await tools.forwarder('/dart', null), launcher.path);
    expect(
      await WindowsNativeHostTools(
        host,
        ProcessRunner(host),
      ).forwarder('/dart', null),
      isNull,
    );
  });

  test('Windows refuses batch compiler shims without a forwarder', () async {
    final tmp = await Directory.systemTemp.createTemp('apple_shims_test-');
    try {
      await expectLater(
        installAppleToolShims(
          tmp.path,
          const AppleToolShimConfig(
            target: IPhoneBuildPlatform(),
            iosSdk: r'C:\SDK\iPhoneOS.sdk',
            clang: r'C:\LLVM\clang.exe',
            hostCompiler: r'C:\LLVM\clang.exe',
            archiver: r'C:\LLVM\llvm-ar.exe',
            linker: r'C:\LLVM\ld64.lld.exe',
            deploymentTarget: '13.0',
            lipo: r'C:\LLVM\llvm-lipo.exe',
            otool: null,
            installNameTool: null,
            xcrun: r'C:\xcross\xcrun.exe',
          ),
          renderer: WindowsAppleToolShimRenderer(_windowsHost()),
        ),
        throwsA(
          isA<FlutterBuildError>().having(
            (e) => e.toString(),
            'message',
            contains('clang.exe'),
          ),
        ),
      );
      expect(File(p.join(tmp.path, 'clang.bat')).existsSync(), isFalse);
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('resolves xcrun beside an overridden launcher', () async {
    final tmp = await Directory.systemTemp.createTemp('apple_shims_launcher-');
    try {
      final launcher = File(p.join(tmp.path, 'xcross'))..writeAsStringSync('');
      final xcrun = File(
        p.join(tmp.path, Platform.isWindows ? 'xcrun.exe' : 'xcrun'),
      )..writeAsStringSync('');
      expect(
        await _resolver(launcher: launcher.path).resolveXcrun(),
        xcrun.path,
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test(
    'declarative xcrun prefers configured tool over launcher sibling',
    () async {
      final tmp = await Directory.systemTemp.createTemp('apple_shims_config-');
      try {
        final launcher = File(p.join(tmp.path, 'xcross'))
          ..writeAsStringSync('');
        File(p.join(tmp.path, 'xcrun')).writeAsStringSync('');
        final resolver = _resolver(
          launcher: launcher.path,
          xcrun: '/configured/xcrun',
          declarative: true,
        );
        expect(await resolver.resolveXcrun(), '/configured/xcrun');
      } finally {
        await tmp.delete(recursive: true);
      }
    },
  );

  test('declarative xcrun only checks a configured launcher sibling', () async {
    final resolver = _resolver(declarative: true);
    await expectLater(
      resolver.resolveXcrun(),
      throwsA(isA<FlutterBuildError>()),
    );
  });

  test('Windows exposes a recognizable clang executable forwarder', () async {
    final tmp = await Directory.systemTemp.createTemp('apple_shims_test-');
    try {
      final forwarder = File(p.join(tmp.path, 'xcross.exe'))
        ..writeAsStringSync('forwarder');
      final xcrun = File(p.join(tmp.path, 'source-xcrun.exe'))
        ..writeAsStringSync('xcrun');
      final shims = Directory(p.join(tmp.path, 'shims'));

      await installAppleToolShims(
        shims.path,
        AppleToolShimConfig(
          target: const IPhoneBuildPlatform(),
          iosSdk: r'C:\SDK\iPhoneOS.sdk',
          clang: r'C:\LLVM\clang.exe',
          hostCompiler: r'C:\LLVM\clang.exe',
          archiver: r'C:\LLVM\llvm-ar.exe',
          linker: r'C:\LLVM\ld64.lld.exe',
          deploymentTarget: '13.0',
          lipo: r'C:\LLVM\llvm-lipo.exe',
          otool: null,
          installNameTool: null,
          xcrun: xcrun.path,
        ),
        toolForwarderExecutable: forwarder.path,
        renderer: WindowsAppleToolShimRenderer(_windowsHost()),
      );

      final clang = File(p.join(shims.path, 'clang.exe'));
      expect(
        File(p.join(shims.path, 'xcrun.exe.sdk')).readAsStringSync(),
        r'C:\SDK\iPhoneOS.sdk',
      );
      expect(clang.existsSync(), isTrue);
      expect(File(p.join(shims.path, 'cc.exe')).existsSync(), isTrue);
      expect(File(p.join(shims.path, 'clang.bat')).existsSync(), isFalse);
      expect(File(p.join(shims.path, 'clang.ps1')).existsSync(), isFalse);
      expect(
        File('${clang.path}.path').readAsStringSync(),
        r'C:\LLVM\clang.exe',
      );
      final arguments = jsonDecode(
        File('${clang.path}.args').readAsStringSync(),
      );
      expect(arguments, contains('--target=arm64-apple-ios13.0'));
      expect(arguments, contains(r'--ld-path=C:\LLVM\ld64.lld.exe'));
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('Apple tool shims expose configured tools including xcrun', () async {
    if (Platform.isWindows) return;
    final tmp = await Directory.systemTemp.createTemp('apple_shims_test-');
    try {
      await installAppleToolShims(
        tmp.path,
        const AppleToolShimConfig(
          target: IPhoneBuildPlatform(),
          iosSdk: '/sdk/iPhoneOS.sdk',
          clang: '/bin/echo',
          hostCompiler: '/bin/echo',
          archiver: '/toolchain/llvm-ar',
          linker: '/toolchain/ld64.lld',
          deploymentTarget: '15.6',
          lipo: '/bin/echo',
          otool: OtoolConfig('/bin/echo', usesObjdump: false),
          installNameTool: '/bin/echo',
          xcrun: '/bin/echo',
        ),
        toolForwarderExecutable: Platform.resolvedExecutable,
        renderer: PosixAppleToolShimRenderer(_linuxHost),
      );
      expect(File(p.join(tmp.path, 'xcrun')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'plutil')).existsSync(), isTrue);
      final xcrun = await Process.run(
        'xcrun',
        const ['--show-sdk-path'],
        environment: {'PATH': tmp.path},
        includeParentEnvironment: false,
      );
      expect(xcrun.exitCode, 0);
      expect(xcrun.stdout.toString().trim(), '--show-sdk-path');

      final version = await Process.run(
        'xcrun',
        const ['--version'],
        environment: {'PATH': tmp.path},
        includeParentEnvironment: false,
      );
      expect(version.exitCode, 0);
      expect(version.stdout.toString(), contains('xcrun version'));
      expect(
        File(p.join(tmp.path, 'ar')).readAsStringSync(),
        contains('/toolchain/llvm-ar'),
      );

      final hostCc = await Process.run(
        'cc',
        const ['-m64', '-Wl,--as-needed', 'host.c'],
        environment: {'PATH': tmp.path},
        includeParentEnvironment: false,
      );
      expect(hostCc.exitCode, 0);
      expect(hostCc.stdout.toString().trim(), '-m64 -Wl,--as-needed host.c');

      final plainCc = await Process.run(
        'cc',
        [
          '-target',
          'arm64-apple-ios15.6',
          '-isysroot',
          '/custom.sdk',
          '--ld-path=/custom/ld',
          'asset.c',
        ],
        // Rust build subprocesses sanitize the hook environment, retaining
        // PATH but not xcross-specific variables. Plain cc must still resolve
        // to the shim, whose cross configuration is embedded in the script.
        environment: {'PATH': tmp.path},
        includeParentEnvironment: false,
      );
      expect(plainCc.exitCode, 0);
      expect(
        plainCc.stdout.toString().trim(),
        '-miphoneos-version-min=15.6 -fuse-ld=lld -target '
        'arm64-apple-ios15.6 -isysroot /custom.sdk '
        '--ld-path=/custom/ld asset.c',
      );

      expect(
        (await Process.run(
          p.join(tmp.path, 'otool'),
          ['-L', 'asset.dylib'],
          environment: const {},
          includeParentEnvironment: false,
        )).stdout.toString().trim(),
        '-L asset.dylib',
      );
      expect(
        (await Process.run(
          p.join(tmp.path, 'install_name_tool'),
          ['-id', '@rpath/asset.dylib', 'asset.dylib'],
          environment: const {},
          includeParentEnvironment: false,
        )).stdout.toString().trim(),
        '-id @rpath/asset.dylib asset.dylib',
      );
      expect(
        (await Process.run(
          p.join(tmp.path, 'codesign'),
          const [],
          environment: const {},
          includeParentEnvironment: false,
        )).exitCode,
        0,
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  });
}

IosEngineCache _workspaceSdk(
  String root,
  String cacheRoot,
  String label, {
  bool sdkLocalEngine = false,
}) {
  for (final path in [
    p.join('packages', 'source'),
    p.join('bin', 'internal', 'source'),
    p.join('bin', 'cache', 'dart-sdk', 'source'),
    p.join('bin', 'cache', 'artifacts', 'fonts', 'source'),
    p.join('bin', 'cache', 'flutter_tools.snapshot'),
    if (sdkLocalEngine) ...[
      p.join('bin', 'cache', 'dart-sdk', 'bin', 'dart'),
      p.join(
        'bin',
        'cache',
        'artifacts',
        'engine',
        'ios',
        'Flutter.xcframework',
        'source',
      ),
      p.join(
        'bin',
        'cache',
        'artifacts',
        'engine',
        'linux-arm64',
        'vm_isolate_snapshot.bin',
      ),
      p.join(
        'bin',
        'cache',
        'artifacts',
        'engine',
        'linux-arm64',
        'isolate_snapshot.bin',
      ),
      p.join(
        'bin',
        'cache',
        'artifacts',
        'engine',
        'common',
        'flutter_patched_sdk',
        'source',
      ),
    ],
  ]) {
    File(p.join(root, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(label);
  }
  File(
    p.join(root, 'bin', 'internal', 'engine.version'),
  ).writeAsStringSync('engine-hash');
  final cache = IosEngineCache(
    targetPolicy: IPhoneFlutterTarget(IPhoneTarget(_linuxHost)),
    hostTools: LinuxNativeHostTools(_linuxHost, ProcessRunner(_linuxHost)),
    flutterRoot: root,
    cacheRoot: cacheRoot,
  );
  Directory(cache.flutterXcframework).createSync(recursive: true);
  Directory(cache.patchedSdkRoot).createSync(recursive: true);
  File(cache.vmSnapshotData)
    ..createSync(recursive: true)
    ..writeAsStringSync(sdkLocalEngine ? label : 'host');
  File(
    cache.isolateSnapshotData,
  ).writeAsStringSync(sdkLocalEngine ? label : 'host');
  return cache;
}

void _expectWorkspaceSdk(FlutterToolWorkspace workspace, String label) {
  for (final path in [
    p.join('packages', 'source'),
    p.join('bin', 'internal', 'source'),
    p.join('bin', 'cache', 'dart-sdk', 'source'),
    p.join('bin', 'cache', 'artifacts', 'fonts', 'source'),
    p.join('bin', 'cache', 'flutter_tools.snapshot'),
  ]) {
    expect(File(p.join(workspace.flutterRoot, path)).readAsStringSync(), label);
  }
}

Future<List<String>> _tree(String root) async {
  final entries = await Directory(root)
      .list(recursive: true, followLinks: false)
      .map((entity) => p.relative(entity.path, from: root))
      .toList();
  entries.sort();
  return entries;
}

Uint8List _dylibMachO(List<String> names) {
  final encoded = names.map(utf8.encode).toList();
  final sizes = [for (final name in encoded) (24 + name.length + 1 + 7) & ~7];
  final commandsSize = sizes.fold(0, (sum, size) => sum + size);
  final bytes = Uint8List(32 + commandsSize);
  final data = ByteData.sublistView(bytes)
    ..setUint32(0, 0xfeedfacf, Endian.little)
    ..setUint32(16, names.length, Endian.little)
    ..setUint32(20, commandsSize, Endian.little);
  var offset = 32;
  for (var index = 0; index < names.length; index++) {
    data
      ..setUint32(offset, index == 0 ? 0x0d : 0x0c, Endian.little)
      ..setUint32(offset + 4, sizes[index], Endian.little)
      ..setUint32(offset + 8, 24, Endian.little);
    bytes.setRange(
      offset + 24,
      offset + 24 + encoded[index].length,
      encoded[index],
    );
    offset += sizes[index];
  }
  return bytes;
}

List<String> _dylibNames(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final count = data.getUint32(16, Endian.little);
  final names = <String>[];
  var offset = 32;
  for (var index = 0; index < count; index++) {
    final size = data.getUint32(offset + 4, Endian.little);
    final start = offset + data.getUint32(offset + 8, Endian.little);
    var end = start;
    while (bytes[end] != 0) {
      end++;
    }
    names.add(utf8.decode(bytes.sublist(start, end)));
    offset += size;
  }
  return names;
}

AppleToolShimResolver<LinuxHost> _resolver({
  String? launcher,
  String? xcrun,
  bool declarative = false,
}) {
  final host = LinuxHost(architecture: 'arm64');
  final runner = ProcessRunner(host);
  return AppleToolShimResolver(
    IPhoneTarget(host),
    runner,
    DarwinSdkRepository(host),
    DarwinToolchainResolver(runner, LinuxDarwinToolchainLocations(host)),
    launcher: launcher,
    xcrun: xcrun,
    declarative: declarative,
    hostTools: LinuxNativeHostTools(host, runner),
    executable: '/isolated/dart',
  );
}

WindowsHost _windowsHost() => WindowsHost(
  architecture: 'x64',
  paths: PosixPaths(),
  processes: _WindowsFixtureProcesses(),
  fileSystem: PosixFileSystem(PosixPaths()),
  environment: const {'PATH': '', 'PATHEXT': '.EXE'},
);

final class _WindowsFixtureProcesses implements HostProcessInterface {
  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    if (arguments.length == 5 && arguments[1] == 'mklink') {
      return Process.start('/bin/ln', [
        '-s',
        arguments[4],
        arguments[3],
      ], mode: mode);
    }
    return Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      mode: mode,
    );
  }

  @override
  Future<String?> findOnShellPath(
    String name, {
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async => name == 'cmd' ? '/fixture/cmd' : null;
  @override
  Future<void> killTree(Process process) async {
    process.kill();
  }
}

final _linuxHost = LinuxHost(architecture: 'arm64');
List<(String, NativeHostTools, FlutterTargetBuildPolicy)> _hostCases() {
  final linuxArm = LinuxHost(architecture: 'arm64');
  final linuxX64 = LinuxHost(architecture: 'x64');
  final macArm = MacOSHost(architecture: 'arm64');
  final macX64 = MacOSHost(architecture: 'x64');
  final windows = _windowsHost();
  return [
    (
      'linux-arm64',
      LinuxNativeHostTools(linuxArm, ProcessRunner(linuxArm)),
      IPhoneFlutterTarget(IPhoneTarget(linuxArm)),
    ),
    (
      'linux-x64',
      LinuxNativeHostTools(linuxX64, ProcessRunner(linuxX64)),
      IPhoneFlutterTarget(IPhoneTarget(linuxX64)),
    ),
    (
      'darwin-arm64',
      MacOSNativeHostTools(macArm, ProcessRunner(macArm)),
      IPhoneFlutterTarget(IPhoneTarget(macArm)),
    ),
    (
      'darwin-x64',
      MacOSNativeHostTools(macX64, ProcessRunner(macX64)),
      IPhoneFlutterTarget(IPhoneTarget(macX64)),
    ),
    (
      'windows-x64',
      WindowsNativeHostTools(windows, ProcessRunner(windows)),
      IPhoneFlutterTarget(IPhoneTarget(windows)),
    ),
  ];
}
