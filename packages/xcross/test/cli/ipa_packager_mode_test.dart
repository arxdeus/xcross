import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/cli/shared/ipa_packager.dart';
import 'package:xcross/src/target/shared/flutter/xcode_build_metadata.dart';

void main() {
  group('IpaPackager.entryMode', () {
    const machO64 = [0xCF, 0xFA, 0xED, 0xFE, 0, 0];
    const fat = [0xCA, 0xFE, 0xBA, 0xBE];

    test('Mach-O is 0755 even when Windows stat lacks exec bits', () {
      expect(IpaPackager.entryMode(0x1B6, machO64), 0x1ED);
      expect(IpaPackager.entryMode(0, fat), 0x1ED);
    });

    test('non-Mach-O keeps host mode, 0644 fallback', () {
      expect(IpaPackager.entryMode(0x1A4, [0x3C, 0x3F]), 0x1A4);
      expect(IpaPackager.entryMode(0x81A4, [1]), 0x1A4);
      expect(IpaPackager.entryMode(0, []), 0x1A4);
    });
  });

  test('xcodeVersionPath on a Windows long-path SDK', () {
    final paths = p.Context(style: p.Style.windows, current: r'C:\proj');
    const sdk =
        r'\\?\C:\sdk\Contents\Developer\Platforms\iPhoneOS.platform'
        r'\Developer\SDKs\iPhoneOS.sdk';
    expect(
      XcodeBuildMetadata.xcodeVersionPath(paths, sdk),
      r'\\?\C:\sdk\Contents\version.plist',
    );
  });

  test('windows join normalizes pbxproj forward slashes', () {
    final paths = p.Context(style: p.Style.windows, current: r'C:\proj');
    final joined = paths.join(r'C:\proj\ios', 'Runner/Runner.entitlements');
    expect(paths.normalize(joined), r'C:\proj\ios\Runner\Runner.entitlements');
    expect(
      paths.equals(joined, r'C:\proj\ios\Runner\Runner.entitlements'),
      isTrue,
    );
    expect(
      paths.basename('Base.lproj/LaunchScreen.storyboard'),
      'LaunchScreen.storyboard',
    );
  });
}
