import 'dart:io';
import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart';
final class WindowsSwiftPmCheckoutAttributes implements SwiftPmCheckoutAttributes {
 WindowsSwiftPmCheckoutAttributes(this.runner);
 final ProcessRunner runner;
 @override Future<void> clear(String path) async {
  if(FileSystemEntity.typeSync(path,followLinks:false)==FileSystemEntityType.notFound)return;
  final result=await runner.run(await runner.locateTool('attrib'),['-R',path]);
  if(result.exitCode!=0)throw FileSystemException('Could not clear read-only checkout placeholder: ${result.stderr}',path);
 }
}
