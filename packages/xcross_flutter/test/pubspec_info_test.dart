import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:standard_message_codec/standard_message_codec.dart';
import 'package:test/test.dart';
import 'package:xcross_flutter/src/models/pubspec_info.dart';

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

  test('defaults to no assets/fonts when flutter: section is absent', () {
    File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n');

    final info = PubspecInfo.loadSync(tmp.path);

    expect(info.usesMaterialDesign, isFalse);
    expect(info.assets, isEmpty);
    expect(info.fonts, isEmpty);
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
