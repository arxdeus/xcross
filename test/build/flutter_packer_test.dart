import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('Windows no longer rejects native iOS plugins', () {
    final source = File('lib/src/build/flutter_packer.dart').readAsStringSync();

    expect(
      source,
      isNot(contains('Native iOS Flutter plugins are not yet supported')),
    );
    expect(source, isNot(contains('Platform.isWindows && nativePlugins')));
    expect(source, contains('if (plugin.usesSwiftPackageManager)'));
    expect(source, contains('else if (plugin.usesCocoaPods)'));
  });
}
