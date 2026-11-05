import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/bundle_pkg_info.dart';

void main() {
  test('default iOS app yields APPL????', () {
    expect(
      BundlePkgInfo.contentsFor(
        '<plist><dict><key>CFBundlePackageType</key><string>APPL</string>'
        '<key>CFBundleSignature</key><string>????</string></dict></plist>',
      ),
      'APPL????',
    );
  });

  test('missing keys fall back to APPL????', () {
    expect(BundlePkgInfo.contentsFor('<plist><dict/></plist>'), 'APPL????');
  });

  test('pads short and truncates long fields to 4 chars', () {
    expect(
      BundlePkgInfo.contentsFor(
        '<plist><dict><key>CFBundlePackageType</key><string>XPC!</string>'
        '<key>CFBundleSignature</key><string>ab</string></dict></plist>',
      ),
      'XPC!ab??',
    );
    expect(
      BundlePkgInfo.contentsFor(
        '<plist><dict><key>CFBundleSignature</key><string>abcdef</string></dict></plist>',
      ),
      'APPLabcd',
    );
  });
}
