import 'dart:io';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_link_creator.dart';
final class PosixSwiftPmCheckoutLinkCreator implements SwiftPmCheckoutLinkCreator {
 const PosixSwiftPmCheckoutLinkCreator();
 @override void create(String link,String target)=>Link(link).createSync(target);
}
