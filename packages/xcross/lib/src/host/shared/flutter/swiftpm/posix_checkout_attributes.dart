import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart';

@internal
final class PosixSwiftPmCheckoutAttributes
    implements SwiftPmCheckoutAttributes {
  const PosixSwiftPmCheckoutAttributes();
  @override
  Future<void> clear(String path) async {}
}
