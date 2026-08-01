import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/build/flutter_packer.dart';
import 'package:xcross/src/constants.dart';

void main() {
  test('Windows no longer rejects native iOS plugins', () {
    final source = File('lib/src/build/flutter_packer.dart').readAsStringSync();

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

  test('uses xcross build, temp, and DevFS names', () {
    final debugBundler = File(
      'lib/src/build/flutter_debug_bundler.dart',
    ).readAsStringSync();
    final packOperation = File(
      'lib/src/build/flutter_pack_operation.dart',
    ).readAsStringSync();
    final hotReload = File(
      'lib/src/build/hot_reload_setup.dart',
    ).readAsStringSync();
    final frontendServer = File(
      'lib/src/device/frontend_server_client.dart',
    ).readAsStringSync();

    expect(debugBundler, contains("'xcross-flutter-debug'"));
    expect(debugBundler, contains("'xcross-flutter-stub-'"));
    expect(packOperation, contains("'xcross-ios'"));
    expect(hotReload, contains("'xcross-flutter-debug'"));
    expect(frontendServer, contains('build/xcross-flutter-debug'));
    expect(DeviceConstants.devFsName, 'xcross');
  });
}
