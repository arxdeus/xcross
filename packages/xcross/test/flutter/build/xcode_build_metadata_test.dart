import 'package:darwin_sdk_kit/target/iphone/iphone_build_platform.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/target/shared/flutter/ios_plist_metadata.dart';
import 'package:xcross/src/target/shared/flutter/xcode_build_metadata.dart';
import 'package:xml/xml.dart';

String _plist(Map<String, String> values) =>
    '<?xml version="1.0"?><plist version="1.0"><dict>'
    '${values.entries.map((e) => '<key>${e.key}</key><string>${e.value}</string>').join()}'
    '</dict></plist>';

void main() {
  final systemVersion = _plist({
    'ProductBuildVersion': '23F81a',
    'ProductVersion': '26.5.1',
  });
  final xcodeVersion = _plist({
    'CFBundleShortVersionString': '26.6',
    'ProductBuildVersion': '17F113',
  });

  test('reads the values Xcode 26.6 / iPhoneOS 26.5 stamp', () {
    final values = XcodeBuildMetadata.fromPlists(
      sdkSystemVersion: systemVersion,
      xcodeVersionPlist: xcodeVersion,
    ).values().map((k, v) => MapEntry(k, v.innerText));
    expect(values, {
      'DTCompiler': 'com.apple.compilers.llvm.clang.1_0',
      'DTPlatformBuild': '23F81a',
      'DTSDKBuild': '23F81a',
      'DTXcode': '2660',
      'DTXcodeBuild': '17F113',
    });
  });

  test('encodes Xcode versions like XCODE_VERSION_ACTUAL', () {
    String? code(String v) => XcodeBuildMetadata.fromPlists(
      xcodeVersionPlist: _plist({'CFBundleShortVersionString': v}),
    ).xcodeVersion;
    expect(code('16.2'), '1620');
    expect(code('9.4.1'), '0941');
    expect(code('26'), '2600');
    expect(code('beta'), isNull);
  });

  test('omits keys whose source is unknown', () {
    expect(const XcodeBuildMetadata().values(), isEmpty);
    final sdkOnly = XcodeBuildMetadata.fromPlists(
      sdkSystemVersion: systemVersion,
      xcodeVersionPlist: 'not xml',
    ).values();
    expect(sdkOnly.keys, isNot(contains('DTXcode')));
    expect(sdkOnly.keys, contains('DTSDKBuild'));
  });

  test('locates SystemVersion and the Xcode version plist', () {
    final paths = p.Context(style: p.Style.windows);
    final sdk = paths.join(
      r'C:\sdk',
      'Developer',
      'Platforms',
      'iPhoneOS.platform',
      'Developer',
      'SDKs',
      'iPhoneOS26.5.sdk',
    );
    expect(
      XcodeBuildMetadata.xcodeVersionPath(paths, sdk),
      paths.join(r'C:\sdk', 'version.plist'),
    );
    expect(
      XcodeBuildMetadata.systemVersionPath(paths, sdk),
      paths.join(
        sdk,
        'System',
        'Library',
        'CoreServices',
        'SystemVersion.plist',
      ),
    );
  });

  test('IosPlistMetadata.overwrite stamps build metadata', () {
    final xml = IosPlistMetadata.overwrite(
      _plist({'DTXcode': 'stale'}),
      platform: const IPhoneBuildPlatform(),
      sdkName: 'iphoneos26.5',
      build: XcodeBuildMetadata.fromPlists(
        sdkSystemVersion: systemVersion,
        xcodeVersionPlist: xcodeVersion,
      ),
    );
    expect(xml, contains('<string>2660</string>'));
    expect(xml, isNot(contains('stale')));
    expect(xml, contains('<key>DTSDKBuild</key><string>23F81a</string>'));
  });
}
