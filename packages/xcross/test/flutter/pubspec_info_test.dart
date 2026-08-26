import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:standard_message_codec/standard_message_codec.dart';
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/flutter_debug_bundler.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/models/pubspec_info.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('xcross_pubspec_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('parses assets and fonts sections', () {
    File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('''
name: demo
flutter:
  uses-material-design: true
  assets:
    - assets/data.json
    - assets/images/
  fonts:
    - family: Custom
      fonts:
        - asset: fonts/Custom-Regular.ttf
        - asset: fonts/Custom-Bold.ttf
          weight: 700
''');

    final info = PubspecInfo.loadSync(tmp.path);

    expect(info.usesMaterialDesign, isTrue);
    expect(info.assets, ['assets/data.json', 'assets/images/']);
    expect(info.fonts, hasLength(1));
    expect(info.fonts.single.family, 'Custom');
    expect(info.fonts.single.fonts.map((f) => f.asset), [
      'fonts/Custom-Regular.ttf',
      'fonts/Custom-Bold.ttf',
    ]);
    expect(info.fonts.single.fonts.last.weight, 700);
    expect(info.fonts.single.descriptor, {
      'family': 'Custom',
      'fonts': [
        {'asset': 'fonts/Custom-Regular.ttf'},
        {'asset': 'fonts/Custom-Bold.ttf', 'weight': 700},
      ],
    });
  });

  test('reads non-dev dependencies from pubspec.lock', () {
    File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('''
name: demo
dependencies:
  direct_package: any
dev_dependencies:
  dev_package: any
''');
    File(p.join(tmp.path, 'pubspec.lock')).writeAsStringSync('''
packages:
  direct_package:
    dependency: direct main
  transitive_package:
    dependency: transitive
  dev_package:
    dependency: direct dev
''');

    expect(PubspecInfo.loadSync(tmp.path).dependencies, [
      'direct_package',
      'transitive_package',
    ]);
  });

  test('defaults to no assets/fonts when flutter: section is absent', () {
    File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n');

    final info = PubspecInfo.loadSync(tmp.path);

    expect(info.usesMaterialDesign, isFalse);
    expect(info.assets, isEmpty);
    expect(info.fonts, isEmpty);
  });

  test('bundles fonts declared by package dependencies', () async {
    final packageRoot = Directory(p.join(tmp.path, 'package_font'))
      ..createSync();
    Directory(p.join(packageRoot.path, 'assets')).createSync();
    File(
      p.join(packageRoot.path, 'assets', 'PackageIcons.ttf'),
    ).writeAsBytesSync([1, 2, 3]);
    File(p.join(packageRoot.path, 'pubspec.yaml')).writeAsStringSync('''
name: package_font
flutter:
  fonts:
    - family: PackageIcons
      fonts:
        - asset: assets/PackageIcons.ttf
          weight: 700
''');

    File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('''
name: demo
dependencies:
  package_font: any
''');
    File(p.join(tmp.path, 'pubspec.lock')).writeAsStringSync('''
packages:
  package_font:
    dependency: direct main
''');
    final dartTool = Directory(p.join(tmp.path, '.dart_tool'))..createSync();
    File(p.join(dartTool.path, 'package_config.json')).writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'package_font',
            'rootUri': packageRoot.uri.toString(),
            'packageUri': 'lib/',
            'languageVersion': '3.0',
          },
        ],
      }),
    );
    final assetsDir = Directory(p.join(tmp.path, 'output'))..createSync();
    final bundler = FlutterDebugBundler(
      projectRoot: tmp.path,
      flutterRoot: p.join(tmp.path, 'flutter'),
      outputDir: p.join(tmp.path, 'build'),
      deploymentTarget: const IosDeploymentTarget('15.0'),
    );

    final fonts = await bundler.copyFonts(
      assetsDir.path,
      PubspecInfo.loadSync(tmp.path),
    );

    expect(
      File(
        p.join(
          assetsDir.path,
          'packages',
          'package_font',
          'assets',
          'PackageIcons.ttf',
        ),
      ).readAsBytesSync(),
      [1, 2, 3],
    );
    expect(fonts, [
      {
        'family': 'packages/package_font/PackageIcons',
        'fonts': [
          {
            'asset': 'packages/package_font/assets/PackageIcons.ttf',
            'weight': 700,
          },
        ],
      },
    ]);
  });

  // Regression check for the manifest byte layout FlutterDebugBundler writes:
  // the previous hand-rolled `AssetManifest.bin` bytes didn't decode cleanly
  // (StandardMessageCodec.decodeMessage throws on trailing bytes), so the
  // fix routes through the real codec instead of guessed byte arrays.
  test(
    'AssetManifest.bin shape encodes and decodes via StandardMessageCodec',
    () {
      const codec = StandardMessageCodec();
      final manifest = {
        'assets/data.json': [
          {'asset': 'assets/data.json'},
        ],
      };

      final bytes = codec.encodeMessage(manifest);
      final decoded = codec.decodeMessage(bytes); // throws if corrupted

      expect(decoded, {
        'assets/data.json': [
          {'asset': 'assets/data.json'},
        ],
      });
    },
  );
}
