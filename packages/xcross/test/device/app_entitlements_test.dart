import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:xcross/src/device/internal/app_capabilities.dart';
import 'package:xcross/src/device/internal/app_entitlements.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'app-entitlements',
    );
  });

  tearDown(() {
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  String appWith(String plist) {
    final app = Directory(p.join(temporaryDirectory.path, 'Runner.app'))
      ..createSync(recursive: true);
    File(p.join(app.path, 'Info.plist')).writeAsStringSync(plist);
    return app.path;
  }

  group('AppEntitlements', () {
    test('reads what the Compose assembler recorded', () {
      final app = appWith(
        PropertyListSerialization.stringWithPropertyList({
          'CFBundleIdentifier': 'com.example.app',
          AppEntitlements.infoPlistKey: {
            'com.apple.developer.associated-domains': [
              'webcredentials:example.com',
            ],
          },
        }),
      );

      expect(AppEntitlements.of(app), {
        'com.apple.developer.associated-domains': [
          'webcredentials:example.com',
        ],
      });
    });

    // This runs on the shared install path, so it also sees Flutter and
    // prebuilt bundles that never carry the key. A plist the XML parser cannot
    // read must not be the reason `xcross flutter run` fails to install.
    test('returns nothing for a binary plist', () {
      final app = Directory(p.join(temporaryDirectory.path, 'Binary.app'))
        ..createSync(recursive: true);
      final data = PropertyListSerialization.dataWithPropertyList({
        'CFBundleIdentifier': 'com.example.app',
      });
      File(p.join(app.path, 'Info.plist')).writeAsBytesSync(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );

      expect(AppEntitlements.of(app.path), isEmpty);
    });

    test('returns nothing for a plist without an XML declaration', () {
      final app = appWith(
        '<plist version="1.0">\n'
        '<dict>\n'
        '\t<key>CFBundleIdentifier</key>\n'
        '\t<string>com.example.app</string>\n'
        '</dict>\n'
        '</plist>\n',
      );

      expect(AppEntitlements.of(app), isEmpty);
    });

    test('returns nothing for an unparseable plist that names the key', () {
      final app = appWith('this is not a plist $AppEntitlements');

      expect(AppEntitlements.of(app), isEmpty);
    });

    test('returns nothing when there is no Info.plist at all', () {
      final app = Directory(p.join(temporaryDirectory.path, 'Empty.app'))
        ..createSync(recursive: true);

      expect(AppEntitlements.of(app.path), isEmpty);
    });
  });

  group('AppCapabilities', () {
    test('reads the capability types the assembler recorded', () {
      final app = appWith(
        PropertyListSerialization.stringWithPropertyList({
          'CFBundleIdentifier': 'com.example.app',
          AppCapabilities.infoPlistKey: ['APPLE_ID_AUTH', 'ASSOCIATED_DOMAINS'],
        }),
      );

      expect(AppCapabilities.of(app), ['APPLE_ID_AUTH', 'ASSOCIATED_DOMAINS']);
    });

    test('returns nothing for a bundle that has no such key', () {
      final app = appWith(
        PropertyListSerialization.stringWithPropertyList({
          'CFBundleIdentifier': 'com.example.app',
        }),
      );

      expect(AppCapabilities.of(app), isEmpty);
    });
  });
}
