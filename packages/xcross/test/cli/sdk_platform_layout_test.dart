import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/sdk_install.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('xcross-sdk-layout-'));
  tearDown(() => root.deleteSync(recursive: true));

  test('includes only the selected platform and toolchain descriptors', () {
    for (final file in sdkIncludedFiles) {
      expect(SdkInstall.sdkRelativePath('Xcode.app/Contents/$file'), file);
      expect(SdkInstall.sdkRelativePath('$file/child'), isNull);
    }
    expect(
      SdkInstall.sdkRelativePath(
        'Developer/Platforms/iPhoneSimulator.platform/Info.plist',
      ),
      isNull,
    );
    expect(
      SdkInstall.sdkRelativePath(
        'Xcode.app/Contents/Developer/Other/Developer/Platforms/iPhoneOS.platform/Info.plist',
      ),
      isNull,
    );
  });

  test(
    'rejects duplicate descriptors before the later entry overwrites',
    () async {
      const descriptor = 'Developer/Platforms/iPhoneOS.platform/Info.plist';
      CpioEntry entry(String name, String contents) => CpioEntry(
        name: name,
        mode: 0x81a4,
        data: Uint8List.fromList(utf8.encode(contents)),
      );
      await expectLater(
        SdkInstall.writeSdkEntries(
          Stream.fromIterable([
            entry('Xcode.app/Contents/$descriptor', 'first'),
            entry('DeviceSupport/Xcode.app/Contents/$descriptor', 'second'),
          ]),
          root.path,
          materializeLinks: true,
        ),
        throwsA(isA<Exception>()),
      );
      expect(
        File(
          p.joinAll([root.path, ...descriptor.split('/')]),
        ).readAsStringSync(),
        'first',
      );
    },
  );

  for (final platform in [
    'iPhoneOS',
    'iPhoneSimulator',
    'AppleTVOS',
    'MacOSX',
  ]) {
    test('recognizes only matching $platform SDK directory aliases', () {
      final sdks = p.join(
        root.path,
        'Developer',
        'Platforms',
        '$platform.platform',
        'Developer',
        'SDKs',
      );
      final generic = p.join(sdks, '$platform.sdk');
      final versioned = p.join(sdks, '${platform}26.0.sdk');
      expect(
        SdkInstall.materializedSdkAliases(root.path, {
          generic: p.basename(versioned),
        }),
        {generic},
      );
      expect(
        SdkInstall.materializedSdkAliases(root.path, {
          versioned: p.basename(generic),
        }),
        {generic},
      );
      expect(
        SdkInstall.materializedSdkAliases(root.path, {
          versioned: 'Other.sdk',
          p.join(sdks, '${platform}25.0.sdk'): p.basename(versioned),
          p.join(sdks, 'header.h'): 'Other.h',
        }),
        isEmpty,
      );
    });
  }

  for (final versionedLink in [false, true]) {
    test('retains SDK contents under both names ($versionedLink)', () async {
      const sdks = 'Developer/Platforms/iPhoneOS.platform/Developer/SDKs';
      final real = versionedLink ? 'iPhoneOS.sdk' : 'iPhoneOS26.0.sdk';
      final alias = versionedLink ? 'iPhoneOS26.0.sdk' : 'iPhoneOS.sdk';
      CpioEntry entry(String name, String data, int mode) => CpioEntry(
        name: name,
        mode: mode,
        data: Uint8List.fromList(utf8.encode(data)),
      );
      await SdkInstall.writeSdkEntries(
        Stream.fromIterable([
          entry('$sdks/$real/usr/include/real.h', 'header', 0x81a4),
          entry('$sdks/$real/usr/include/link.h', 'real.h', 0xa1ff),
          entry('$sdks/$alias', real, 0xa1ff),
        ]),
        root.path,
        materializeLinks: true,
      );
      final base = p.joinAll([root.path, ...sdks.split('/')]);
      expect(Directory(p.join(base, 'iPhoneOS.sdk')).existsSync(), isTrue);
      expect(
        File(
          p.join(base, 'iPhoneOS26.0.sdk', 'usr', 'include', 'link.h'),
        ).readAsStringSync(),
        'header',
      );
      expect(
        File(
          p.join(base, 'iPhoneOS.sdk', 'usr', 'include', 'link.h'),
        ).readAsStringSync(),
        'header',
      );
    });
  }

  test('does not classify aliases outside the imported bundle', () {
    expect(
      () => SdkInstall.materializedSdkAliases(root.path, {
        p.join(root.path, 'SDKs', 'Example.sdk'): '../../outside/Example26.sdk',
      }),
      throwsA(isA<Exception>()),
    );
  });
}
