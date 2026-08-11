import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/package_config_resolver.dart';

void _writePackageConfig(String directory) {
  final file = File(
    p.join(directory, '.dart_tool', 'package_config.json'),
  );
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    jsonEncode(<String, Object>{
      'configVersion': 2,
      'packages': <Object>[],
    }),
  );
}

void main() {
  group('PackageConfigResolver', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync(
        'package_config_resolver_test-',
      );
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    test('finds a standalone project package config', () async {
      _writePackageConfig(temp.path);

      final result = await PackageConfigResolver.find(temp.path);

      expect(
        result,
        p.join(temp.path, '.dart_tool', 'package_config.json'),
      );
    });

    test('finds a workspace package config in an ancestor', () async {
      final app = Directory(p.join(temp.path, 'apps', 'example'))
        ..createSync(recursive: true);
      _writePackageConfig(temp.path);

      final result = await PackageConfigResolver.find(app.path);

      expect(
        result,
        p.join(temp.path, '.dart_tool', 'package_config.json'),
      );
    });

    test('prefers a local package config over an ancestor', () async {
      final app = Directory(p.join(temp.path, 'apps', 'example'))
        ..createSync(recursive: true);
      _writePackageConfig(temp.path);
      _writePackageConfig(app.path);

      final result = await PackageConfigResolver.find(app.path);

      expect(
        result,
        p.join(app.path, '.dart_tool', 'package_config.json'),
      );
    });

    test('find returns null when no package config exists', () async {
      expect(await PackageConfigResolver.find(temp.path), isNull);
    });

    test('require reports the directory and recovery command', () async {
      await expectLater(
        PackageConfigResolver.require(temp.path),
        throwsA(
          isA<FlutterBuildError>()
              .having(
                (error) => error.message,
                'message',
                contains(temp.path),
              )
              .having(
                (error) => error.message,
                'message',
                contains('pub get'),
              ),
        ),
      );
    });
  });
}
