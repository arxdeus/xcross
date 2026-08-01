import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/darwinsdk/darwin_sdk.dart';
import 'package:xcross/src/util/errors.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross_darwin_sdk-');
  });

  tearDown(() => tmp.delete(recursive: true));

  String sdksDir(String bundle) => p.join(
    bundle,
    'Developer',
    'Platforms',
    'iPhoneOS.platform',
    'Developer',
    'SDKs',
  );

  group('native bundle', () {
    test('uses xcross artifact-bundle storage', () {
      final expected = p.join(
        tmp.path,
        'xcross',
        'swift-sdks',
        'xcross-darwin.artifactbundle',
      );
      expect(DarwinSdk.nativeInstallDir(configDir: tmp.path), expected);
      expect(DarwinSdk(expected).swiftSdkPath, expected);
    });

    test('current accepts only a complete bundle', () async {
      final bundle = p.join(tmp.path, 'xcross-darwin.artifactbundle');
      final frameworks = p.join(
        sdksDir(bundle),
        'iPhoneOS18.2.sdk',
        'System',
        'Library',
        'Frameworks',
      );
      await Directory(frameworks).create(recursive: true);
      await Directory(
        p.join(
          bundle,
          'Developer',
          'Toolchains',
          'XcodeDefault.xctoolchain',
          'usr',
          'lib',
          'swift',
          'iphoneos',
        ),
      ).create(recursive: true);

      expect(DarwinSdk.current(bundle: bundle), isNull);
      await File(p.join(bundle, 'info.json')).writeAsString('{}');
      expect(DarwinSdk.current(bundle: bundle), isNull);
      await File(p.join(bundle, 'swift-sdk.json')).writeAsString('{}');
      expect(DarwinSdk.current(bundle: bundle), isNull);
      await File(p.join(bundle, 'toolset.json')).writeAsString('{}');

      final sdk = DarwinSdk.current(bundle: bundle);
      expect(sdk, isNotNull);
      expect(sdk!.bundle, bundle);
    });

    test('rejects metadata with an empty SDK directory', () async {
      final bundle = p.join(tmp.path, 'xcross-darwin.artifactbundle');
      await Directory(
        p.join(sdksDir(bundle), 'iPhoneOS18.2.sdk'),
      ).create(recursive: true);
      await File(p.join(bundle, 'info.json')).writeAsString('{}');
      await File(p.join(bundle, 'swift-sdk.json')).writeAsString('{}');

      expect(DarwinSdk.isValidBundle(bundle), isFalse);
    });
  });

  group('iPhoneOSSdk', () {
    test('prefers a versioned SDK over an unversioned one', () async {
      final dir = sdksDir(tmp.path);
      await Directory(p.join(dir, 'iPhoneOS.sdk')).create(recursive: true);
      await Directory(p.join(dir, 'iPhoneOS17.5.sdk')).create(recursive: true);

      final sdk = DarwinSdk(tmp.path);
      expect(sdk.iPhoneOSSdk(), p.join(dir, 'iPhoneOS17.5.sdk'));
    });

    test(
      'returns the only versioned SDK when no unversioned one exists',
      () async {
        final dir = sdksDir(tmp.path);
        await Directory(p.join(dir, 'iPhoneOS26.sdk')).create(recursive: true);

        final sdk = DarwinSdk(tmp.path);
        expect(sdk.iPhoneOSSdk(), p.join(dir, 'iPhoneOS26.sdk'));
      },
    );

    test('falls back to the unversioned SDK when it is the only one', () async {
      final dir = sdksDir(tmp.path);
      await Directory(p.join(dir, 'iPhoneOS.sdk')).create(recursive: true);

      final sdk = DarwinSdk(tmp.path);
      expect(sdk.iPhoneOSSdk(), p.join(dir, 'iPhoneOS.sdk'));
    });

    test(
      'throws XcrossError when the SDKs dir exists but has no matches',
      () async {
        await Directory(sdksDir(tmp.path)).create(recursive: true);

        final sdk = DarwinSdk(tmp.path);
        expect(
          sdk.iPhoneOSSdk,
          throwsA(
            isA<XcrossError>().having(
              (error) => error.message,
              'message',
              contains('Could not find an iPhoneOS SDK'),
            ),
          ),
        );
      },
    );

    test('throws XcrossError when the SDKs dir does not exist', () {
      final sdk = DarwinSdk(tmp.path);
      expect(
        sdk.iPhoneOSSdk,
        throwsA(
          isA<XcrossError>().having(
            (error) => error.message,
            'message',
            contains('Could not find an iPhoneOS SDK'),
          ),
        ),
      );
    });
  });
}
