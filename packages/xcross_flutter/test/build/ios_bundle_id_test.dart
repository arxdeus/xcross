import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross_flutter/src/build/ios_bundle_id.dart';
import 'package:xcross_flutter/src/errors.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_ios_bundle_id-');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<void> writePlist(String cfBundleIdentifier) async {
    final dir = Directory(p.join(tmp.path, 'ios', 'Runner'));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'Info.plist')).writeAsString(
      '<?xml version="1.0"?>\n'
      '<plist version="1.0">\n'
      '<dict>\n'
      '\t<key>CFBundleIdentifier</key>\n'
      '\t<string>$cfBundleIdentifier</string>\n'
      '</dict>\n'
      '</plist>\n',
    );
  }

  Future<void> writePbxproj(String productBundleId) async {
    final dir = Directory(p.join(tmp.path, 'ios', 'Runner.xcodeproj'));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'project.pbxproj')).writeAsString('''
/* Begin XCBuildConfiguration section */
		97C146ED1CF9000F00755E36 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				PRODUCT_BUNDLE_IDENTIFIER = $productBundleId;
				PRODUCT_NAME = "\$(TARGET_NAME)";
			};
			name = Debug;
		};
/* End XCBuildConfiguration section */
''');
  }

  test('uses literal CFBundleIdentifier from Info.plist', () async {
    await writePlist('com.example.Literal');
    await writePbxproj('com.example.FromPbx');

    expect(IosBundleId.resolve(tmp.path), 'com.example.Literal');
  });

  test(
    r'reads PRODUCT_BUNDLE_IDENTIFIER from pbxproj when plist has $(VAR)',
    () async {
      await writePlist(r'$(PRODUCT_BUNDLE_IDENTIFIER)');
      await writePbxproj('com.example.FromPbx');

      expect(IosBundleId.resolve(tmp.path), 'com.example.FromPbx');
    },
  );

  test('reads PRODUCT_BUNDLE_IDENTIFIER when Info.plist is missing', () async {
    await writePbxproj('com.example.OnlyPbx');

    expect(IosBundleId.resolve(tmp.path), 'com.example.OnlyPbx');
  });

  test('strips optional quotes around PRODUCT_BUNDLE_IDENTIFIER', () async {
    await writePlist(r'$(PRODUCT_BUNDLE_IDENTIFIER)');
    final dir = Directory(p.join(tmp.path, 'ios', 'Runner.xcodeproj'));
    await dir.create(recursive: true);
    await File(
      p.join(dir.path, 'project.pbxproj'),
    ).writeAsString('PRODUCT_BUNDLE_IDENTIFIER = "com.example.Quoted";\n');

    expect(IosBundleId.resolve(tmp.path), 'com.example.Quoted');
  });

  test('throws when neither plist nor pbxproj yields a bundle id', () {
    expect(
      () => IosBundleId.resolve(tmp.path),
      throwsA(
        isA<FlutterBuildError>().having(
          (e) => e.message,
          'message',
          contains('Could not resolve iOS bundle identifier'),
        ),
      ),
    );
  });
}
