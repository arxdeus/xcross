import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/flutter_packer.dart';
import 'package:xcross/src/flutter/constants.dart';

/// Resolves a path under `lib/src/flutter/` without depending on the working
/// directory the suite happens to be launched from.
String _flutterSrc(String relative) => File.fromUri(
  Isolate.resolvePackageUriSync(
    Uri.parse('package:xcross/src/flutter/$relative'),
  )!,
).parent.path;

String _read(String relative) =>
    File('${_flutterSrc(relative)}/${p.basename(relative)}').readAsStringSync();

void main() {
  test('Windows no longer rejects native iOS plugins', () {
    final source = _read('build/flutter_packer.dart');

    expect(
      source,
      isNot(contains('Native iOS Flutter plugins are not yet supported')),
    );
    expect(source, isNot(contains('Platform.isWindows && nativePlugins')));
    expect(source, contains('if (plugin.usesSwiftPackageManager)'));
    expect(source, contains('else if (plugin.usesCocoaPods)'));
  });

  test('copies every SwiftPM dylib into Frameworks', () async {
    final tmp = await Directory.systemTemp.createTemp('flutter_packer_test-');
    try {
      final frameworks = Directory(p.join(tmp.path, 'Frameworks'))
        ..createSync();
      final aggregate = File(p.join(tmp.path, 'libAggregate.dylib'))
        ..writeAsStringSync('aggregate');
      final dependency = File(p.join(tmp.path, 'libDependency.dylib'))
        ..writeAsStringSync('dependency');

      await FlutterPacker.copyPluginLibraries([
        aggregate.path,
        dependency.path,
      ], frameworks.path);

      expect(
        File(
          p.join(frameworks.path, p.basename(aggregate.path)),
        ).readAsStringSync(),
        'aggregate',
      );
      expect(
        File(
          p.join(frameworks.path, p.basename(dependency.path)),
        ).readAsStringSync(),
        'dependency',
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('copies native-asset frameworks recursively into Frameworks', () async {
    final tmp = await Directory.systemTemp.createTemp('native_framework_test-');
    try {
      final source = Directory(p.join(tmp.path, 'Foo.framework'))..createSync();
      File(p.join(source.path, 'Foo')).writeAsStringSync('binary');
      Directory(p.join(source.path, 'Resources')).createSync();
      File(
        p.join(source.path, 'Resources', 'Info.plist'),
      ).writeAsStringSync('plist');
      final destination = Directory(p.join(tmp.path, 'Frameworks'))
        ..createSync();

      await FlutterPacker.copyNativeAssetFrameworks([
        source.path,
      ], destination.path);

      expect(
        File(
          p.join(destination.path, 'Foo.framework', 'Foo'),
        ).readAsStringSync(),
        'binary',
      );
      expect(
        File(
          p.join(destination.path, 'Foo.framework', 'Resources', 'Info.plist'),
        ).readAsStringSync(),
        'plist',
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('copies GoogleService-Info.plist into the app bundle', () async {
    final tmp = await Directory.systemTemp.createTemp('flutter_packer_test-');
    try {
      final project = Directory(p.join(tmp.path, 'project'))..createSync();
      final ios = Directory(p.join(project.path, 'ios'))..createSync();
      final bundle = Directory(p.join(tmp.path, 'Runner.app'))..createSync();
      File(
        p.join(ios.path, 'GoogleService-Info.plist'),
      ).writeAsStringSync('firebase');

      await FlutterPacker.copyOptionalRunnerResources(
        project.path,
        bundle.path,
      );

      expect(
        File(
          p.join(bundle.path, 'GoogleService-Info.plist'),
        ).readAsStringSync(),
        'firebase',
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('prefers Runner GoogleService-Info.plist', () async {
    final tmp = await Directory.systemTemp.createTemp('flutter_packer_test-');
    try {
      final project = Directory(p.join(tmp.path, 'project'))..createSync();
      final ios = Directory(p.join(project.path, 'ios'))..createSync();
      final runner = Directory(p.join(ios.path, 'Runner'))..createSync();
      final bundle = Directory(p.join(tmp.path, 'Runner.app'))..createSync();
      File(
        p.join(ios.path, 'GoogleService-Info.plist'),
      ).writeAsStringSync('ios');
      File(
        p.join(runner.path, 'GoogleService-Info.plist'),
      ).writeAsStringSync('runner');

      await FlutterPacker.copyOptionalRunnerResources(
        project.path,
        bundle.path,
      );

      expect(
        File(
          p.join(bundle.path, 'GoogleService-Info.plist'),
        ).readAsStringSync(),
        'runner',
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('uses xcross build, temp, and DevFS names', () {
    final debugBundler = _read('build/flutter_debug_bundler.dart');
    final packOperation = _read('build/flutter_pack_operation.dart');
    final hotReload = _read('build/hot_reload_setup.dart');
    // Scanned as a directory, not a fixed filename: the incremental dill path
    // has already moved once (out of the deleted frontend_server_client.dart,
    // when frontend_server driving was extracted into the project-agnostic
    // package:frontend_server_kit) and naming a single file broke this test.
    final hotReloadLayer = Directory(
      _flutterSrc('hot_reload/source_watcher.dart'),
    ).listSync(recursive: true).whereType<File>().map((f) => f.path);
    expect(hotReloadLayer, isNotEmpty, reason: 'hot_reload sources not found');
    final hotReloadSources = hotReloadLayer
        .map(File.new)
        .map((f) => f.readAsStringSync())
        .join('\n');

    expect(debugBundler, contains("'xcross-flutter-debug'"));
    expect(
      debugBundler,
      isNot(contains("'NativeAssetsManifest.json'")),
      reason: 'the native-assets builder owns this manifest',
    );
    expect(debugBundler, contains("'xcross-flutter-stub-'"));
    expect(packOperation, contains("'xcross-ios'"));
    expect(hotReload, contains("'xcross-flutter-debug'"));
    expect(hotReloadSources, contains('build/xcross-flutter-debug'));
    expect(FlutterDeviceConstants.devFsName, 'xcross');
  });
}
