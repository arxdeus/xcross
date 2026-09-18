import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/compose/build/compose_entitlements.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('compose-entitlements');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String write(String relative, String contents) {
    final file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
    return file.path;
  }

  String entitlements(Map<String, String> entries) =>
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
      '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      '<plist version="1.0">\n'
      '<dict>\n'
      '${entries.entries.map((e) => '\t<key>${e.key}</key>\n\t${e.value}\n').join()}'
      '</dict>\n'
      '</plist>\n';

  group('find', () {
    // The app target's entitlements sit next to its @main Swift file, so the
    // directory the detector already found is both the cheapest and the most
    // accurate place to look.
    test('prefers the known app directory over anything else', () {
      final wanted = write(
        p.join('app', 'iosApp', 'Runner.entitlements'),
        entitlements({}),
      );
      write(p.join('iosApp', 'Other.entitlements'), entitlements({}));

      expect(
        ComposeEntitlements.find(
          root.path,
          'Example',
          appDir: p.join(root.path, 'app', 'iosApp'),
        ),
        wanted,
      );
    });

    test('falls back to the iosApp/iosApp layout', () {
      final wanted = write(
        p.join('iosApp', 'iosApp', 'App.entitlements'),
        entitlements({}),
      );

      expect(ComposeEntitlements.find(root.path, 'Example'), wanted);
    });

    test('falls back to the iosApp layout', () {
      final wanted = write(
        p.join('iosApp', 'App.entitlements'),
        entitlements({}),
      );

      expect(ComposeEntitlements.find(root.path, 'Example'), wanted);
    });

    test('finds an app kept outside the conventional layouts', () {
      final wanted = write(
        p.join('app', 'ios', 'Example.entitlements'),
        entitlements({}),
      );

      expect(ComposeEntitlements.find(root.path, 'Example'), wanted);
    });

    test('prefers the file named after the app', () {
      write(p.join('iosApp', 'Other.entitlements'), entitlements({}));
      final wanted = write(
        p.join('iosApp', 'Example.entitlements'),
        entitlements({}),
      );

      expect(ComposeEntitlements.find(root.path, 'Example'), wanted);
    });

    // Guessing would enable capabilities on an App ID for a target that never
    // asked for them, which is a change to the user's Apple account.
    test('refuses to guess between ambiguous candidates', () {
      write(p.join('one', 'A.entitlements'), entitlements({}));
      write(p.join('two', 'B.entitlements'), entitlements({}));

      expect(ComposeEntitlements.find(root.path, 'Example'), isNull);
    });

    test('ignores build output and dependency checkouts', () {
      write(p.join('build', 'bin', 'Copy.entitlements'), entitlements({}));
      write(p.join('Pods', 'Other.entitlements'), entitlements({}));

      expect(ComposeEntitlements.find(root.path, 'Example'), isNull);
    });

    test('returns null when the project has none', () {
      expect(ComposeEntitlements.find(root.path, 'Example'), isNull);
    });
  });

  group('read', () {
    test('parses the app target entitlements', () {
      write(
        p.join('iosApp', 'Example.entitlements'),
        entitlements({
          'com.apple.developer.applesignin':
              '<array><string>Default</string>'
              '</array>',
          'aps-environment': '<string>development</string>',
        }),
      );

      expect(ComposeEntitlements.read(root.path, 'Example'), {
        'com.apple.developer.applesignin': ['Default'],
        'aps-environment': 'development',
      });
    });

    // These values only ever add capabilities to the profile, so a file Xcode
    // itself may never have required must not turn a project that builds today
    // into one that does not.
    test('treats a malformed entitlements file as none', () {
      write(p.join('iosApp', 'Example.entitlements'), 'not a plist at all');

      expect(ComposeEntitlements.read(root.path, 'Example'), isNull);
    });

    test('treats a non-dictionary root as none', () {
      write(
        p.join('iosApp', 'Example.entitlements'),
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n'
        '<array><string>nope</string></array>\n'
        '</plist>\n',
      );

      expect(ComposeEntitlements.read(root.path, 'Example'), isNull);
    });

    test('returns null when there is nothing to read', () {
      expect(ComposeEntitlements.read(root.path, 'Example'), isNull);
    });
  });
}
