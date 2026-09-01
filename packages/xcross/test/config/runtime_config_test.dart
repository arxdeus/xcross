import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/cli/ide/xcross_executable.dart';
import 'package:xcross/src/compose/toolchain/compose_host.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain_resolver.dart';
import 'package:xcross/src/flutter/build/flutter_packer.dart';
import 'package:xcross/xcross.dart';

void main() {
  late Directory temporary;

  setUp(() {
    XcrossRuntimeConfig.resetForTests();
    temporary = Directory.systemTemp.createTempSync('xcross-runtime-config-');
  });
  tearDown(() {
    XcrossRuntimeConfig.resetForTests();
    temporary.deleteSync(recursive: true);
  });

  test('absent config initializes legacy context', () async {
    final runtime = await XcrossRuntimeConfig.initialize(
      configDirectory: temporary.path,
      environment: const {'HOME': '/home/test', 'SECRET': 'legacy-visible'},
      windows: false,
    );

    expect(runtime.isLegacy, isTrue);
    expect(runtime.config, isNull);
    expect(runtime.environment['SECRET'], 'legacy-visible');
    expect(XcrossRuntimeConfig.current, same(runtime));
  });

  test(
    'present config overlays explicit tools and prepends configured PATH',
    () async {
      final git = File(p.join(temporary.path, 'git'))
        ..writeAsStringSync('#!/bin/sh\n');
      final swiftBin = Directory(p.join(temporary.path, 'swift-bin'))
        ..createSync();
      final llvmBin = Directory(p.join(temporary.path, 'llvm-bin'))
        ..createSync();
      final swift = File(p.join(swiftBin.path, 'swift'))..createSync();
      final clang = File(p.join(llvmBin.path, 'clang'))..createSync();
      if (!Platform.isWindows) Process.runSync('chmod', ['755', git.path]);
      File(p.join(temporary.path, 'config.yaml')).writeAsStringSync('''
roots:
  flutterSdk: /flutter
  darwinSdk: /darwin
  xcross: /bin/xcross
  javaHome: /configured/java
  konanData: /configured/konan
toolchains:
  swift: ${swiftBin.path}
  llvm: ${llvmBin.path}
tools:
  git.exe: ${git.path}
environment:
  PATH:
    - /tools
''');
      final inheritedPath = Platform.environment['PATH'] ?? '';
      final runtime = await XcrossRuntimeConfig.initialize(
        configDirectory: temporary.path,
        environment: {
          'HOME': '/home/test',
          'SECRET': 'inherited',
          'PATH': inheritedPath,
        },
        windows: false,
      );

      expect(runtime.isConfigured, isTrue);
      expect(runtime.config!.tool('git'), git.path);
      expect(runtime.environment, {
        'PATH': ['/tools'],
      });
      expect(runtime.processEnvironment['SECRET'], 'inherited');
      final process = ProcessRunner.configuration!;
      expect(process.normalizedTools['git'], git.path);
      expect(process.toolchainDirectories['swift'], [swiftBin.path]);
      expect(process.toolchainDirectories['llvm'], [llvmBin.path]);
      expect(await ProcessRunner.which('swift'), swift.path);
      expect(await ProcessRunner.which('clang'), clang.path);
      expect(
        process.effectiveChildEnvironment,
        containsPair('PATH', '/tools:$inheritedPath'),
      );
      expect(
        process.effectiveChildEnvironment,
        containsPair('SECRET', 'inherited'),
      );
      expect(
        process.effectiveChildEnvironment,
        containsPair('JAVA_HOME', '/configured/java'),
      );
      expect(
        process.effectiveChildEnvironment,
        containsPair('KONAN_DATA_DIR', '/configured/konan'),
      );
      expect(
        process.effectiveChildEnvironment,
        containsPair('XCROSS_CONFIG', p.join(temporary.path, 'config.yaml')),
      );
      expect(
        await ProcessRunner.which('git'),
        git.path,
        reason: 'explicit override wins over PATH',
      );
      expect(
        await ProcessRunner.which('dart'),
        isNotNull,
        reason: 'unspecified tools remain discoverable through inherited PATH',
      );
      expect(DarwinSdk.nativeInstallDir(), '/darwin');
      expect(
        await FlutterPacker.resolveFlutterRoot(
          projectRoot: temporary.path,
          root: '/explicit/flutter',
        ),
        '/explicit/flutter',
      );
      expect(
        ComposeSetupOptions.resolve(
          env: const {'KONAN_DATA_DIR': '/environment/konan'},
          projectRoot: temporary.path,
          host: ComposeHost.linuxX64,
        ).cacheRoot,
        '/configured/konan',
      );
      expect(
        resolveXcrossExecutable(subcommand: 'vscode', brokenFeature: 'DAP'),
        '/bin/xcross',
      );
    },
  );

  test('rejects an explicit invalid tool override', () async {
    File(p.join(temporary.path, 'config.yaml')).writeAsStringSync('''
 tools:
   git: ${p.join(temporary.path, 'missing-git')}
''');

    await expectLater(
      XcrossRuntimeConfig.initialize(
        configDirectory: temporary.path,
        environment: const {'HOME': '/home/test'},
        windows: false,
      ),
      throwsA(isA<XcrossConfigException>()),
    );
  });

  test(
    'current requires initialization and reset supports isolated tests',
    () async {
      expect(() => XcrossRuntimeConfig.current, throwsStateError);
      await XcrossRuntimeConfig.initialize(
        configDirectory: temporary.path,
        environment: const {'HOME': '/home/test'},
        windows: false,
      );
      expect(XcrossRuntimeConfig.isInitialized, isTrue);

      XcrossRuntimeConfig.resetForTests();
      expect(XcrossRuntimeConfig.isInitialized, isFalse);
      expect(() => XcrossRuntimeConfig.current, throwsStateError);
    },
  );

  test('absent config retains legacy static overrides', () async {
    ProcessRunner.configure(
      normalizedTools: const {'git': '/legacy/git'},
      effectiveChildEnvironment: const {'LEGACY': '1'},
    );
    FlutterPacker.configureFlutterRootOverride('/legacy/flutter');
    ComposeSetupOptions.configureCacheRootOverride('/legacy/konan');
    DarwinSdk.configureInstallBundleOverride('/legacy/darwin');
    configureXcrossLauncherOverride('/legacy/xcross');

    await XcrossRuntimeConfig.initialize(
      configDirectory: temporary.path,
      environment: const {'HOME': '/home/test'},
      windows: false,
    );

    expect(ProcessRunner.configuration!.normalizedTools['git'], '/legacy/git');
    expect(DarwinSdk.nativeInstallDir(), '/legacy/darwin');
    expect(
      await FlutterPacker.resolveFlutterRoot(projectRoot: temporary.path),
      '/legacy/flutter',
    );
    expect(
      ComposeSetupOptions.resolve(
        env: const {'KONAN_DATA_DIR': '/environment/konan'},
        projectRoot: temporary.path,
        host: ComposeHost.linuxX64,
      ).cacheRoot,
      '/legacy/konan',
    );
    expect(
      resolveXcrossExecutable(subcommand: 'vscode', brokenFeature: 'DAP'),
      '/legacy/xcross',
    );
  });

  test('concurrent and repeated initialization returns one context', () async {
    final values = await Future.wait([
      XcrossRuntimeConfig.initialize(
        configDirectory: temporary.path,
        environment: const {'HOME': '/home/test'},
        windows: false,
      ),
      XcrossRuntimeConfig.initialize(
        configDirectory: temporary.path,
        environment: const {'HOME': '/home/test'},
        windows: false,
      ),
    ]);
    expect(values[0], same(values[1]));
    expect(await XcrossRuntimeConfig.initialize(), same(values[0]));
  });
}
