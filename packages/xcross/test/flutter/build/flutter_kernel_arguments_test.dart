import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/dart_plugin_registrant.dart';
import 'package:xcross/src/shared/flutter/build/internal/kernel_compiler.dart';
import 'package:xcross/src/shared/flutter/flutter_kernel_compiler.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';

import '../flutter_test_runtime.dart';

void main() {
  const defines = [
    'USER=1',
    'FLUTTER_APP_FLAVOR=staging',
    'FLUTTER_BUILD_NAME=1.2.3',
    'FLUTTER_BUILD_NUMBER=4',
    'FLUTTER_VERSION=3.47.0',
  ];
  late String flutterRoot;
  setUpAll(() {
    final flutter = Directory.systemTemp.createTempSync('xcross_kernel_args_');
    addTearDown(() => flutter.deleteSync(recursive: true));
    File(p.join(flutter.path, 'bin', 'internal', 'engine.version'))
      ..createSync(recursive: true)
      ..writeAsStringSync('engine-hash\n');
    flutterRoot = flutter.path;
  });
  final runtime = testIPhoneRuntime();

  List<String> argumentsFor(
    FlutterBuildMode mode, {
    List<String> dartDefines = defines,
  }) =>
      FlutterKernelCompiler(
        runtime: runtime,
        registrant: DartPluginRegistrant(
          runtime.host.fileSystem,
          runtime.host.paths.context,
        ),
        projectRoot: '/project',
        flutterRoot: flutterRoot,
        buildMode: mode,
        dartDefines: dartDefines,
      ).frontendServerArguments(
        compiler: const KernelCompiler(
          snapshot: '/frontend_server_aot.dart.snapshot',
          runtime: '/dartaotruntime',
          runtimeName: 'dartaotruntime',
          isAot: true,
        ),
        engineCache: runtime.engineCache(flutterRoot, mode: mode),
        packageConfig: '/packages.json',
        outputDill: '/app.dill',
        entrypointArg: 'package:app/main.dart',
      );

  String sdk(FlutterBuildMode mode) =>
      '${runtime.engineCache(flutterRoot, mode: mode).patchedSdkRoot}/';

  test('release matches flutter build ios --release', () {
    expect(
      sdk(FlutterBuildMode.release),
      endsWith('flutter_patched_sdk_product/'),
    );
    expect(argumentsFor(FlutterBuildMode.release), [
      '/frontend_server_aot.dart.snapshot',
      '--sdk-root',
      sdk(FlutterBuildMode.release),
      '--target=flutter',
      '--no-print-incremental-dependencies',
      for (final define in defines) '-D$define',
      '-Ddart.vm.profile=false',
      '-Ddart.vm.product=true',
      '--delete-tostring-package-uri=dart:ui',
      '--delete-tostring-package-uri=package:flutter',
      '--aot',
      '--tfa',
      '--target-os',
      'ios',
      '--packages',
      '/packages.json',
      '--output-dill',
      '/app.dill',
      'package:app/main.dart',
    ]);
  });

  test('profile matches flutter build ios --profile', () {
    expect(argumentsFor(FlutterBuildMode.profile), [
      '/frontend_server_aot.dart.snapshot',
      '--sdk-root',
      sdk(FlutterBuildMode.profile),
      '--target=flutter',
      '--no-print-incremental-dependencies',
      for (final define in defines) '-D$define',
      '-Ddart.vm.profile=true',
      '-Ddart.vm.product=false',
      '--delete-tostring-package-uri=dart:ui',
      '--delete-tostring-package-uri=package:flutter',
      '--aot',
      '--tfa',
      '--target-os',
      'ios',
      '--packages',
      '/packages.json',
      '--output-dill',
      '/app.dill',
      'package:app/main.dart',
    ]);
  });

  test('debug compiles a hot-reloadable kernel with asserts', () {
    expect(argumentsFor(FlutterBuildMode.debug), [
      '/frontend_server_aot.dart.snapshot',
      '--sdk-root',
      sdk(FlutterBuildMode.debug),
      '--target=flutter',
      '--no-print-incremental-dependencies',
      '-Ddart.developer.serviceExtensionStream.enabled=true',
      for (final define in defines) '-D$define',
      '-Ddart.vm.profile=false',
      '-Ddart.vm.product=false',
      '--enable-asserts',
      '--track-widget-creation',
      '--packages',
      '/packages.json',
      '--output-dill',
      '/app.dill',
      'package:app/main.dart',
    ]);
  });

  test('user dart.vm defines win in debug and profile, never in release', () {
    const user = ['dart.vm.product=true', 'dart.vm.profile=true'];
    for (final mode in [FlutterBuildMode.debug, FlutterBuildMode.profile]) {
      final arguments = argumentsFor(mode, dartDefines: user);
      expect(arguments.where((argument) => argument.startsWith('-Ddart.vm.')), [
        '-Ddart.vm.product=true',
        '-Ddart.vm.profile=true',
      ], reason: mode.name);
    }
    final release = argumentsFor(FlutterBuildMode.release, dartDefines: user);
    expect(release.where((argument) => argument.startsWith('-Ddart.vm.')), [
      '-Ddart.vm.product=true',
      '-Ddart.vm.profile=true',
      '-Ddart.vm.profile=false',
      '-Ddart.vm.product=true',
    ]);
  });

  test('each mode keeps its own intermediates directory', () {
    expect(FlutterBuildMode.values.map((mode) => mode.intermediatesDirectory), [
      'xcross-flutter-debug',
      'xcross-flutter-profile',
      'xcross-flutter-release',
    ]);
  });
}
