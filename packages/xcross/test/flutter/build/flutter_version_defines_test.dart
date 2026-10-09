import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/flutter_version_defines.dart';

void main() {
  const document = {
    'frameworkVersion': '3.47.0',
    'channel': 'stable',
    'repositoryUrl': 'https://github.com/flutter/flutter.git',
    'frameworkRevision': '4cf24164269a5ebf0c16a028a00727d0e77bbb05',
    'engineRevision': '5f77625673248ee5846fbcaf5d3e1a3878386fd7',
    'dartSdkVersion': '3.13.0',
  };
  const defines = [
    'FLUTTER_VERSION=3.47.0',
    'FLUTTER_CHANNEL=stable',
    'FLUTTER_GIT_URL=https://github.com/flutter/flutter.git',
    'FLUTTER_FRAMEWORK_REVISION=4cf2416426',
    'FLUTTER_ENGINE_REVISION=5f77625673',
    'FLUTTER_DART_VERSION=3.13.0',
  ];

  test('version defines use the short revisions flutter_tools uses', () {
    expect(FlutterVersionDefines.fromJson(document), defines);
    expect(FlutterVersionDefines.fromJson({'channel': 'stable'}), isEmpty);
  });

  group('read', () {
    late Directory flutter;
    setUp(() => flutter = Directory.systemTemp.createTempSync('xcross_ver_'));
    tearDown(() => flutter.deleteSync(recursive: true));

    File versionFile() =>
        File(p.join(flutter.path, 'bin', 'cache', 'flutter.version.json'))
          ..parent.createSync(recursive: true);

    test('reads bin/cache/flutter.version.json', () {
      versionFile().writeAsStringSync(jsonEncode(document));
      expect(FlutterVersionDefines.read(LinuxHost(), flutter.path), defines);
    });

    test('is empty when the file is missing', () {
      expect(FlutterVersionDefines.read(LinuxHost(), flutter.path), isEmpty);
    });

    test('is empty when the file is malformed', () {
      versionFile().writeAsStringSync('{"frameworkVersion": ');
      expect(FlutterVersionDefines.read(LinuxHost(), flutter.path), isEmpty);
      versionFile().writeAsStringSync('[]');
      expect(FlutterVersionDefines.read(LinuxHost(), flutter.path), isEmpty);
    });
  });
}
