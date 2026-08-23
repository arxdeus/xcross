import 'package:test/test.dart';
import 'package:xcross/src/version.dart';

void main() {
  test('the committed build identity is unreleased', () {
    expect(XcrossVersion.current, 'unreleased');
    expect(XcrossVersion.isReleased, isFalse);
    expect(XcrossVersion.isDev, isTrue);
    expect(XcrossVersion.describe(), 'xcross unreleased (unreleased build)');
  });
}
