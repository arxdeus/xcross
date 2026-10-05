import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/shared/posix_paths.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/host/windows/windows_paths.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:darwin_sdk_kit/host/macos/macos_darwin_toolchain_locations.dart';
import 'package:darwin_sdk_kit/host/shared/darwin_toolchain_locations.dart';
import 'package:darwin_sdk_kit/host/windows/windows_darwin_toolchain_locations.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_build_platform.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_target.dart';
import 'package:darwin_sdk_kit/target/simulator/simulator_build_platform.dart';
import 'package:darwin_sdk_kit/target/simulator/simulator_target.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/linux/flutter/native_host_tools.dart';
import 'package:xcross/src/host/macos/flutter/native_host_tools.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer_posix.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';
import 'package:xcross/src/host/windows/flutter/apple_tool_shim_renderer.dart';
import 'package:xcross/src/host/windows/flutter/native_host_tools.dart';
import 'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/shared/flutter/errors.dart';

import 'support/native_flutter_fixtures.dart';

void main() {
  final macOSPaths = PosixPaths();
  declarativeXcrunTests<MacOSHost>(
    'macOS',
    '/selected bundle',
    macOSPaths,
    (files, processes, environment) => MacOSHost(
      architecture: 'arm64',
      paths: macOSPaths,
      fileSystem: files,
      processes: processes,
      environment: environment,
    ),
    MacOSDarwinToolchainLocations.new,
    MacOSNativeHostTools.new,
  );
  final windowsPaths = WindowsPaths(currentDirectory: r'C:\');
  declarativeXcrunTests<WindowsHost>(
    'Windows',
    r'C:\selected bundle',
    windowsPaths,
    (files, processes, environment) => WindowsHost(
      architecture: 'arm64',
      paths: windowsPaths,
      fileSystem: files,
      processes: processes,
      environment: environment,
    ),
    WindowsDarwinToolchainLocations.new,
    WindowsNativeHostTools.new,
  );
  constructorOwnedOtoolTests();

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
      final host = MacOSHost(
        architecture: 'arm64',
        paths: PosixPaths(context: p.Context()),
      );
      final runner = ProcessRunner(
        host,
        log: nativeTestLog(),
        stdinStream: const Stream<List<int>>.empty(),
        stdoutSink: nativeTestSink(),
        stderrSink: nativeTestSink(),
      );
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

  test('Windows uses the resolved clang as its host C compiler', () async {
    final host = windowsFixtureHost();
    final compiler = await WindowsNativeHostTools(
      host,
      ProcessRunner(
        host,
        log: nativeTestLog(),
        stdinStream: const Stream<List<int>>.empty(),
        stdoutSink: nativeTestSink(),
        stderrSink: nativeTestSink(),
      ),
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
      ProcessRunner(
        host,
        log: nativeTestLog(),
        stdinStream: const Stream<List<int>>.empty(),
        stdoutSink: nativeTestSink(),
        stderrSink: nativeTestSink(),
      ),
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
        stdinStream: const Stream<List<int>>.empty(),
        stdoutSink: nativeTestSink(),
        stderrSink: nativeTestSink(),
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
      stdinStream: const Stream<List<int>>.empty(),
      stdoutSink: nativeTestSink(),
      stderrSink: nativeTestSink(),
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
    await expectLater(
      WindowsNativeHostTools(
        host,
        ProcessRunner(
          host,
          log: nativeTestLog(),
          stdinStream: const Stream<List<int>>.empty(),
          stdoutSink: nativeTestSink(),
          stderrSink: nativeTestSink(),
        ),
      ).forwarder('/dart', null),
      throwsA(
        isA<FlutterBuildError>().having(
          (error) => error.toString(),
          'message',
          contains('No xcross.exe was found'),
        ),
      ),
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

  test('declarative xcrun rejects missing trusted siblings', () async {
    final resolver = appleToolResolver(declarative: true);
    await expectLater(
      resolver.resolveXcrun(),
      throwsA(isA<FlutterBuildError>()),
    );
  });

  test(
    'Windows rsync shim copies frameworks the way flutter assemble asks',
    () async {
      final tmp = await Directory.systemTemp.createTemp('apple_shims_rsync-');
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
        final deep = p.joinAll([tmp.path, ...List.filled(12, 'nested-dir')]);
        final framework = Directory(p.join(deep, 'Flutter.framework'));
        File(p.join(framework.path, 'Headers', 'Flutter.h'))
          ..createSync(recursive: true)
          ..writeAsStringSync('header');
        File(p.join(framework.path, 'Flutter')).writeAsStringSync('binary');
        File(p.join(framework.path, '.DS_Store')).writeAsStringSync('junk');
        final output = Directory(p.join(tmp.path, 'out'))..createSync();
        File(
          p.join(output.path, 'Flutter.framework', 'stale'),
        ).createSync(recursive: true);

        final result = await Process.run(
          'rsync',
          [
            '-av',
            '--delete',
            '--filter',
            '- .DS_Store/',
            '--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r',
            framework.path,
            output.path,
          ],
          environment: {
            'PATH': '${shims.path};${Platform.environment['PATH']}',
          },
          runInShell: true,
        );

        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
        final copied = p.join(output.path, 'Flutter.framework');
        expect(File(p.join(copied, 'Flutter')).readAsStringSync(), 'binary');
        expect(
          File(p.join(copied, 'Headers', 'Flutter.h')).existsSync(),
          isTrue,
        );
        expect(File(p.join(copied, '.DS_Store')).existsSync(), isFalse);
        expect(File(p.join(copied, 'stale')).existsSync(), isFalse);
      } finally {
        await tmp.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );

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

@internal
void declarativeXcrunTests<T extends PlatformHostInterface>(
  String label,
  String root,
  HostPathsInterface paths,
  T Function(HostFileSystemInterface, HostProcessInterface, Map<String, String>)
  createHost,
  DarwinToolchainLocationsInterface Function(T) createLocations,
  NativeHostTools<T> Function(T, ProcessRunner<T>) createHostTools,
) {
  group('$label declarative packaged xcrun', () {
    late MappedXcrunFileSystem files;
    late XcrunTestProcesses processes;
    late T host;
    late ProcessRunner<T> runner;
    final executable = paths.context.join(
      root,
      'current',
      paths.executableName('xcross'),
    );
    final constructorLauncher = paths.context.join(
      root,
      'configured',
      paths.executableName('xcross'),
    );
    final callLauncher = paths.context.join(
      root,
      'per-call',
      paths.executableName('xcross'),
    );
    String sibling(String launcher) => paths.context.join(
      paths.context.dirname(launcher),
      paths.executableName('xcrun'),
    );
    final currentSibling = sibling(executable);
    final constructorSibling = sibling(constructorLauncher);
    final callSibling = sibling(callLauncher);
    final ambientSibling = paths.context.join(
      root,
      'ambient',
      paths.executableName('xcrun'),
    );

    setUp(() async {
      final backing = await Directory.systemTemp.createTemp('selected-xcrun-');
      addTearDown(() => backing.delete(recursive: true));
      files = MappedXcrunFileSystem(backing.path, root, paths.context);
      processes = XcrunTestProcesses(ambientSibling);
      host = createHost(files, processes, {
        'PATH': paths.context.dirname(ambientSibling),
        'PATHEXT': '.EXE',
      });
      runner = ProcessRunner(
        host,
        log: nativeTestLog(),
        stdinStream: const Stream<List<int>>.empty(),
        stdoutSink: nativeTestSink(),
        stderrSink: nativeTestSink(),
      );
      files.write(ambientSibling);
    });

    AppleToolShimResolver<T> resolver({String? launcher, String? xcrun}) =>
        AppleToolShimResolver(
          SimulatorTarget(host),
          runner,
          DarwinSdkRepository(host, log: nativeTestLog()),
          DarwinToolchainResolver(runner, createLocations(host)),
          hostTools: createHostTools(host, runner),
          executable: executable,
          launcher: launcher,
          xcrun: xcrun,
          declarative: true,
        );

    tearDown(() {
      expect(processes.shellLookups, isEmpty);
      expect(processes.starts, isEmpty);
    });

    test('uses injected executable sibling without a launcher', () async {
      files.write(currentSibling);
      expect(await resolver().resolveXcrun(), currentSibling);
      expect(files.lookups, [currentSibling]);
    });

    test(
      'rejects absent helper even when ambient xcrun is available',
      () async {
        await expectLater(
          resolver().resolveXcrun(),
          throwsA(
            isA<FlutterBuildError>().having(
              (error) => error.toString(),
              'message',
              contains('xcrun not configured'),
            ),
          ),
        );
        expect(files.lookups, [currentSibling]);
      },
    );

    test('rejects a directory named like the helper', () async {
      Directory(files.map(currentSibling)).createSync(recursive: true);
      await expectLater(
        resolver().resolveXcrun(),
        throwsA(isA<FlutterBuildError>()),
      );
      expect(files.lookups, [currentSibling]);
    });

    test('explicit tool overrides every bundled sibling', () async {
      for (final path in [currentSibling, constructorSibling, callSibling]) {
        files.write(path);
      }
      final configured = paths.context.join(
        root,
        'override',
        paths.executableName('xcrun'),
      );
      expect(
        await resolver(
          launcher: constructorLauncher,
          xcrun: configured,
        ).resolveXcrun(launcher: callLauncher),
        configured,
      );
      expect(files.lookups, isEmpty);
    });

    test('constructor launcher wins over per-call and executable', () async {
      for (final path in [currentSibling, constructorSibling, callSibling]) {
        files.write(path);
      }
      expect(
        await resolver(
          launcher: constructorLauncher,
        ).resolveXcrun(launcher: callLauncher),
        constructorSibling,
      );
      expect(files.lookups, [constructorSibling]);
    });

    test('per-call launcher wins over injected executable', () async {
      files.write(currentSibling);
      files.write(callSibling);
      expect(
        await resolver().resolveXcrun(launcher: callLauncher),
        callSibling,
      );
      expect(files.lookups, [callSibling]);
    });

    test('missing launcher helper still checks injected executable', () async {
      files.write(currentSibling);
      files.write(callSibling);
      expect(
        await resolver(
          launcher: constructorLauncher,
        ).resolveXcrun(launcher: callLauncher),
        currentSibling,
      );
      expect(files.lookups, [constructorSibling, currentSibling]);
    });

    test('empty explicit tool still checks injected executable', () async {
      files.write(currentSibling);
      expect(await resolver(xcrun: '').resolveXcrun(), currentSibling);
      expect(files.lookups, [currentSibling]);
    });
  });
}

@internal
void constructorOwnedOtoolTests() {
  group('constructor-owned otool resolution', () {
    const root = '/selected llvm';
    const otool = '$root/llvm-otool';
    const objdump = '$root/llvm-objdump';
    late MappedXcrunFileSystem files;
    late XcrunTestProcesses processes;
    late AppleToolShimResolver<MacOSHost> resolver;

    setUp(() async {
      final backing = await Directory.systemTemp.createTemp('selected-otool-');
      addTearDown(() => backing.delete(recursive: true));
      final paths = PosixPaths();
      files = MappedXcrunFileSystem(backing.path, root, paths.context);
      processes = XcrunTestProcesses('$root/ambient-xcrun');
      final host = MacOSHost(
        architecture: 'arm64',
        paths: paths,
        fileSystem: files,
        processes: processes,
        environment: const {'PATH': root},
      );
      final runner = ProcessRunner(
        host,
        log: nativeTestLog(),
        stdinStream: const Stream<List<int>>.empty(),
        stdoutSink: nativeTestSink(),
        stderrSink: nativeTestSink(),
      );
      resolver = AppleToolShimResolver(
        SimulatorTarget(host),
        runner,
        DarwinSdkRepository(host, log: nativeTestLog()),
        DarwinToolchainResolver(runner, const SelectedOtoolLocations()),
        hostTools: MacOSNativeHostTools(host, runner),
        executable: '$root/xcross',
        declarative: true,
      );
    });

    tearDown(() {
      expect(processes.shellLookups, isEmpty);
      expect(processes.starts, isEmpty);
    });

    test('prefers llvm-otool without probing llvm-objdump', () async {
      files.write(otool);
      files.write(objdump);
      final result = await resolver.resolveOtool();
      expect(result?.executable, otool);
      expect(result?.usesObjdump, isFalse);
      expect(files.lookups, [otool]);
    });

    test('falls back from llvm-otool to llvm-objdump', () async {
      files.write(objdump);
      final result = await resolver.resolveOtool();
      expect(result?.executable, objdump);
      expect(result?.usesObjdump, isTrue);
      expect(files.lookups, [otool, objdump]);
    });

    test('returns null when neither tool exists', () async {
      expect(await resolver.resolveOtool(), isNull);
      expect(files.lookups, [otool, objdump]);
    });
  });
}

@internal
final class SelectedOtoolLocations
    implements DarwinToolchainLocationsInterface {
  const SelectedOtoolLocations();

  @override
  List<String> llvmToolDirectories() => const [];
  @override
  String get linkerInstallationHint => 'unused';
  @override
  String get clangInstallationHint => 'unused';
}

@internal
final class MappedXcrunFileSystem implements HostFileSystemInterface {
  MappedXcrunFileSystem(this.backingRoot, this.root, this.paths);

  final String backingRoot;
  final String root;
  final p.Context paths;
  final List<String> lookups = [];

  String map(String path) {
    if (!paths.isWithin(root, path)) {
      throw StateError('outside selected filesystem: $path');
    }
    return p.joinAll([
      backingRoot,
      ...paths.split(paths.relative(path, from: root)),
    ]);
  }

  void write(String path) => File(map(path))
    ..createSync(recursive: true)
    ..writeAsStringSync('bundled xcrun');

  @override
  File file(String path) {
    lookups.add(path);
    return File(map(path));
  }

  @override
  Directory directory(String path) => throw UnsupportedError('unused');
  @override
  Link link(String path) => throw UnsupportedError('unused');
  @override
  void makeExecutable(String path) => throw UnsupportedError('unused');
  @override
  void setPermissions(String path, int mode) =>
      throw UnsupportedError('unused');
  @override
  Future<void> createArchiveLink(String destination, String target) =>
      throw UnsupportedError('unused');
}

@internal
final class XcrunTestProcesses implements HostProcessInterface {
  @override
  ProcessExitDiagnostic describeExit(int exitCode) =>
      throw StateError('Unexpected process exit: $exitCode');

  XcrunTestProcesses(this.ambientXcrun);

  final String ambientXcrun;
  final List<String> shellLookups = [];
  final List<String> starts = [];

  @override
  Future<String?> findOnShellPath(
    String name, {
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async {
    shellLookups.add(name);
    return ambientXcrun;
  }

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
    starts.add(executable);
    throw StateError('unexpected process: $executable');
  }

  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) => throw UnsupportedError('unused');
}
