@TestOn('!windows')
library;

import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/hot_reload_setup.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';

import '../flutter_test_runtime.dart';

void main() {
  late Directory project;
  late Directory flutter;
  setUp(() {
    project = Directory.systemTemp.createTempSync('xcross_hot_reload_project_');
    flutter = Directory(p.join(project.path, 'flutter'))..createSync();
    final snapshots = Directory(
      p.join(flutter.path, 'bin', 'cache', 'dart-sdk', 'bin', 'snapshots'),
    )..createSync(recursive: true);
    File(
      p.join(snapshots.path, 'frontend_server_aot.dart.snapshot'),
    ).writeAsStringSync('fixture');
    Directory(
      p.join(
        flutter.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'common',
        'flutter_patched_sdk',
      ),
    ).createSync(recursive: true);
    Directory(p.join(project.path, '.dart_tool')).createSync();
    File(
      p.join(project.path, '.dart_tool', 'package_config.json'),
    ).writeAsStringSync('{"configVersion":2,"packages":[]}');
  });
  tearDown(() => project.deleteSync(recursive: true));

  const defines = [
    'VALUE=1',
    'FLUTTER_BUILD_NAME=1.0.0',
    'FLUTTER_BUILD_NUMBER=1',
    'FLUTTER_VERSION=3.47.0',
  ];

  Future<void> verify(
    FlutterBuildRuntime<LinuxHost> runtime,
    String intermediate,
  ) async {
    final config = await HotReloadSetup.buildHotReloadConfig(
      runtime: runtime,
      projectRoot: project.path,
      target: 'lib/main.dart',
      dartDefines: defines,
    );
    expect(config, isNotNull);
    expect(config!.projectRoot, project.path);
    expect(config.entrypoint, p.join(project.path, 'lib', 'main.dart'));
    expect(config.outputDill, p.join(intermediate, '.hotreload', 'app.dill'));
    expect(config.warmDill, p.join(intermediate, '.kernel', 'app.dill'));
    expect(config.dartDefines, defines);
    expect(Directory(p.dirname(config.outputDill)).existsSync(), isTrue);
  }

  test(
    'physical hot reload preserves exact artifact names and explicit project root',
    () async {
      final runtime = testIPhoneRuntime(
        resolution: FlutterResolutionConfiguration(
          executable: '/xcross',
          root: flutter.path,
        ),
      );
      await verify(
        runtime,
        p.join(project.path, 'build', 'xcross-flutter-debug'),
      );
    },
  );

  test(
    'simulator hot reload uses isolated warm kernel and output directories',
    () async {
      final runtime = testSimulatorRuntime(
        resolution: FlutterResolutionConfiguration(
          executable: '/xcross',
          root: flutter.path,
        ),
      );
      await verify(
        runtime,
        p.join(
          project.path,
          'build',
          'xcross-ios-simulator',
          'xcross-flutter-debug',
        ),
      );
    },
  );
}
