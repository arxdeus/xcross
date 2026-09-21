import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/doctor_environment_checks.dart';
import 'package:xcross/src/cli/basic/internal/xcode_swift_requirement.dart';

void main() {
  group('XcodeSwiftRequirement.xcodeMajorFromXipPath', () {
    test('reads the version out of the usual download names', () {
      expect(XcodeSwiftRequirement.xcodeMajorFromXipPath('Xcode_27.0.xip'), 27);
      expect(
        XcodeSwiftRequirement.xcodeMajorFromXipPath(
          p.join('downloads', 'Xcode_27.0_beta_3.xip'),
        ),
        27,
      );
      expect(XcodeSwiftRequirement.xcodeMajorFromXipPath('Xcode-26.4.xip'), 26);
    });

    test('is undecided about a renamed archive', () {
      expect(XcodeSwiftRequirement.xcodeMajorFromXipPath('xcode.xip'), isNull);
      expect(XcodeSwiftRequirement.xcodeMajorFromXipPath('sdk.xip'), isNull);
    });
  });

  group('XcodeSwiftRequirement.xcodeMajorFromSdkPath', () {
    test('reads the versioned iPhoneOS SDK name', () {
      expect(
        XcodeSwiftRequirement.xcodeMajorFromSdkPath(
          p.join('SDKs', 'iPhoneOS27.0.sdk'),
        ),
        27,
      );
    });

    test('is undecided about the unversioned symlink', () {
      expect(
        XcodeSwiftRequirement.xcodeMajorFromSdkPath(
          p.join('SDKs', 'iPhoneOS.sdk'),
        ),
        isNull,
      );
    });
  });

  group('XcodeSwiftRequirement.mismatch', () {
    String? check(int xcode, String version) => XcodeSwiftRequirement.mismatch(
      xcodeMajor: xcode,
      swiftVersionOutput: version,
      swiftPath: '/usr/bin/swift',
    );

    test('rejects Swift older than 6.4 for an Xcode 27 SDK', () {
      expect(
        check(27, 'Swift version 6.3 (swift-6.3-RELEASE)'),
        allOf(contains('Xcode 27'), contains('6.4 or newer'), contains('6.3')),
      );
      expect(check(27, 'Apple Swift version 5.10 (swiftlang-5.10)'), isNotNull);
    });

    test('accepts 6.4 and newer', () {
      expect(check(27, 'Swift version 6.4 (swift-6.4-RELEASE)'), isNull);
      expect(check(27, 'Swift version 6.10-dev'), isNull);
      expect(check(27, 'Swift version 7.0 (swift-7.0-RELEASE)'), isNull);
    });

    test('has no opinion about older Xcode generations', () {
      expect(check(26, 'Swift version 6.1 (swift-6.1-RELEASE)'), isNull);
    });

    test('stays silent when the toolchain reports no version', () {
      // swiftly and mise proxies answer nothing; blocking on that would be
      // worse than the diagnostic this check exists to improve.
      expect(check(27, ''), isNull);
      expect(check(27, 'swift-driver version 1.90'), isNull);
    });
  });

  group('DoctorEnvironmentChecks.swiftTooOldForSdk', () {
    late Directory bundle;

    setUp(() => bundle = Directory.systemTemp.createTempSync('xcross_xcsdk_'));
    tearDown(() => bundle.deleteSync(recursive: true));

    void sdkNamed(String name) => Directory(
      p.join(
        bundle.path,
        'Developer',
        'Platforms',
        'iPhoneOS.platform',
        'Developer',
        'SDKs',
        name,
      ),
    ).createSync(recursive: true);

    Future<String?> run(String version) =>
        DoctorEnvironmentChecks.swiftTooOldForSdk(
          bundle.path,
          toolchainIdentity: () async => {
            'swift': '/usr/bin/swift',
            'version': version,
          },
        );

    test('fails an Xcode 27 SDK paired with Swift 6.3', () async {
      sdkNamed('iPhoneOS27.0.sdk');
      expect(
        await run('Swift version 6.3 (swift-6.3-RELEASE)'),
        allOf(contains('Xcode 27'), contains('6.4 or newer')),
      );
    });

    test('passes the same SDK with Swift 6.4', () async {
      sdkNamed('iPhoneOS27.0.sdk');
      expect(await run('Swift version 6.4 (swift-6.4-RELEASE)'), isNull);
    });

    test('passes an older SDK with an older Swift', () async {
      sdkNamed('iPhoneOS26.0.sdk');
      expect(await run('Swift version 6.1 (swift-6.1-RELEASE)'), isNull);
    });

    test('says nothing when no SDK is installed', () async {
      expect(await run('Swift version 6.3'), isNull);
    });
  });
}
