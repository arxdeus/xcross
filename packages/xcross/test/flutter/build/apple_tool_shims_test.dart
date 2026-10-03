import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/host/linux/flutter/native_host_tools.dart';
import 'package:xcross/src/host/macos/flutter/native_host_tools.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer_posix.dart';
import 'package:xcross/src/host/windows/flutter/apple_tool_shim_renderer.dart';
import 'package:xcross/src/host/windows/flutter/native_host_tools.dart';

import 'support/native_flutter_fixtures.dart';

void main() {
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
        renderer: WindowsAppleToolShimRenderer(windowsFixtureHost()),
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
      final runner = ProcessRunner(host, log: nativeTestLog());
      final resolver = AppleToolShimResolver(
        IPhoneTarget(host),
        runner,
        DarwinSdkRepository(host, log: nativeTestLog()),
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

  test('Windows uses the resolved clang as its host C compiler', () async {
    final host = windowsFixtureHost();
    final compiler = await WindowsNativeHostTools(
      host,
      ProcessRunner(host, log: nativeTestLog()),
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
      ProcessRunner(host, log: nativeTestLog()),
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
        log: nativeTestLog(),
      );
      final compiler = await LinuxNativeHostTools(
        host,
        runner,
      ).compiler('/cross/clang');
      expect(compiler.executable, '/host/cc');
      expect(compiler.arguments, isEmpty);
    },
  );

  test('Windows resolves native forwarders and configured launchers', () async {
    final tmp = await Directory.systemTemp.createTemp('native-forwarder-');
    addTearDown(() => tmp.delete(recursive: true));
    final launcher = File(p.join(tmp.path, 'xcross.exe'))
      ..writeAsStringSync('');
    final host = windowsFixtureHost();
    final runner = ProcessRunner(
      host,
      configuration: ProcessConfiguration(
        normalizedTools: {'xcross': launcher.path},
        effectiveChildEnvironment: const {},
      ),
      log: nativeTestLog(),
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
        ProcessRunner(host, log: nativeTestLog()),
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
          renderer: WindowsAppleToolShimRenderer(windowsFixtureHost()),
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
      final xcrun = File(p.join(tmp.path, 'xcrun'))..writeAsStringSync('');
      expect(
        await appleToolResolver(launcher: launcher.path).resolveXcrun(),
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
        final resolver = appleToolResolver(
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
    final resolver = appleToolResolver(declarative: true);
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
        renderer: WindowsAppleToolShimRenderer(windowsFixtureHost()),
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
        renderer: PosixAppleToolShimRenderer(LinuxHost(architecture: 'arm64')),
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
  }, skip: Platform.isWindows);
}
