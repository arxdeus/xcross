import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_linker_compatibility.dart';

void main() {
  test('provides Objective-C linker flags as Swift driver arguments', () {
    expect(objectiveCLinkerSwiftDriverArguments, [
      '-Xswiftc',
      '-Xlinker',
      '-Xswiftc',
      '-ObjC',
      '-Xswiftc',
      '-Xlinker',
      '-Xswiftc',
      '-no_objc_category_merging',
    ]);
  });
}
