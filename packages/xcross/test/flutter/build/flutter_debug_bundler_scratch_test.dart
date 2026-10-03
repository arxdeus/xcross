@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/dart_plugin_registrant.dart';
import 'package:xcross/src/flutter/build/flutter_debug_bundler.dart';
import 'package:xcross/src/flutter/build/internal/toolchain.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_plugins.dart';
import 'package:xcross/src/shared/flutter/flutter_assets_compiler.dart';
import 'package:xcross/src/shared/flutter/flutter_kernel_compiler.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';

import '../flutter_test_runtime.dart';

void main() {
  test(
    'stub scratch uses selected host temp rather than native process temp',
    () async {
      final project = Directory.systemTemp.createTempSync(
        'xcross_stub_fixture_',
      );
      addTearDown(() => project.deleteSync(recursive: true));
      final selected = Directory(p.join(project.path, 'selected-host-temp'))
        ..createSync();
      final host = LinuxHost(
        currentDirectory: project.path,
        temporaryDirectory: selected.path,
      );
      final runtime = testFlutterRuntime(
        IPhoneFlutterTarget(IPhoneTarget(host)),
      );
      final compiler = File(p.join(project.path, 'stand-in-compiler'))
        ..writeAsStringSync(r'''
#!/bin/sh
previous=''
source=''
output=''
for argument in "$@"; do
  if [ "$previous" = '-o' ]; then output="$argument"; fi
  case "$argument" in *debug_app.c) source="$argument" ;; esac
  previous="$argument"
done
printf '%s' "$source" > "$output"
''');
      host.fileSystem.makeExecutable(compiler.path);
      final framework = p.join(project.path, 'App.framework');
      final bundler = FlutterDebugBundler(
        runtime: runtime,
        kernel: FlutterKernelCompiler(
          runtime: runtime,
          registrant: DartPluginRegistrant(host.fileSystem),
          plugins: PluginDiscovery(host.fileSystem),
          projectRoot: project.path,
          flutterRoot: '/unused',
        ),
        assets: FlutterAssetsCompiler(
          fileSystem: host.fileSystem,
          projectRoot: project.path,
          flutterRoot: '/unused',
        ),
        projectRoot: project.path,
        flutterRoot: '/unused',
        outputDir: project.path,
        deploymentTarget: IosDeploymentTarget(
          '13.0',
          platform: runtime.target.buildPlatform,
        ),
      );
      await bundler.buildAppStub(
        framework,
        Toolchain(clang: compiler.path, iosSdk: '/unused', linker: '/unused'),
      );
      final compiledSource = File(p.join(framework, 'App')).readAsStringSync();
      expect(
        compiledSource,
        startsWith(p.join(selected.path, 'xcross-flutter-stub-')),
      );
      expect(p.basename(compiledSource), 'debug_app.c');
      expect(selected.listSync(), isEmpty);
    },
  );
}
