// Tests for `xcross sdk install`'s filtering/path-rewriting logic only —
// against small in-memory synthetic entry names, not `extractXcodeXipContent`
// itself (already tested in test/darwinsdk/xcode_xip_extractor_test.dart).
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xcross/src/cli/sdk_command.dart';
import 'package:xcross/src/darwinsdk/cpio_reader.dart';

void main() {
  test('filters a mixed CpioEntry list down to just SDK entries', () {
    final entries = [
      CpioEntry(
        name:
            'Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/'
            'Developer/SDKs/iPhoneOS17.5.sdk/usr/include/stdio.h',
        mode: 0x81a4, // regular file, rw-r--r--
        data: Uint8List(0),
      ),
      CpioEntry(
        name:
            'Xcode.app/Contents/Developer/Platforms/MacOSX.platform/'
            'Developer/SDKs/MacOSX14.sdk/usr/include/stdio.h',
        mode: 0x81a4,
        data: Uint8List(0),
      ),
      CpioEntry(
        name: 'Xcode.app/Contents/Info.plist',
        mode: 0x81a4,
        data: Uint8List(0),
      ),
    ];

    final relativePaths = entries
        .map((e) => sdkRelativePath(e.name))
        .whereType<String>()
        .toList();

    const expectedIPhoneOSHeader =
        'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/'
        'iPhoneOS17.5.sdk/usr/include/stdio.h';
    expect(relativePaths, [expectedIPhoneOSHeader]);
  });

  group('sdkRelativePath', () {
    test('strips an Xcode.app-style prefix down to the SDK anchor', () {
      const name =
          'Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/'
          'Developer/SDKs/iPhoneOS17.5.sdk/usr/include/stdio.h';
      expect(
        sdkRelativePath(name),
        'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/'
        'iPhoneOS17.5.sdk/usr/include/stdio.h',
      );
    });

    test('keeps a name already rooted at the anchor unchanged', () {
      const name =
          'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/'
          'iPhoneOS17.5.sdk/System/Library/Frameworks/UIKit.framework/'
          'UIKit.tbd';
      expect(sdkRelativePath(name), name);
    });

    test('returns null for entries outside the iPhoneOS SDK sysroot', () {
      expect(
        sdkRelativePath(
          'Xcode.app/Contents/Developer/Platforms/MacOSX.platform/'
          'Developer/SDKs/MacOSX14.sdk/usr/include/stdio.h',
        ),
        isNull,
      );
      expect(sdkRelativePath('Xcode.app/Contents/Info.plist'), isNull);
    });

    test('returns null for an unrelated top-level file', () {
      expect(sdkRelativePath('README.md'), isNull);
    });
  });
}
