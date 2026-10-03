import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/checkout_link_creator.dart';
final class WindowsSwiftPmCheckoutLinkCreator implements SwiftPmCheckoutLinkCreator {
 late final library=DynamicLibrary.open('kernel32.dll');
 late final createLink=library.lookupFunction<Uint8 Function(Pointer<Utf16>,Pointer<Utf16>,Uint32),int Function(Pointer<Utf16>,Pointer<Utf16>,int)>('CreateSymbolicLinkW');
 late final lastError=library.lookupFunction<Uint32 Function(),int Function()>('GetLastError');
 @override void create(String link,String target) {
  final resolved=p.isAbsolute(target)?target:p.join(p.dirname(link),target);
  final flags=Directory(resolved).existsSync()?1:0;
  final destination=p.absolute(link).toNativeUtf16();
  final source=target.toNativeUtf16();
  try {
   if(createLink(destination,source,flags|2)!=0)return;
   if(createLink(destination,source,flags)!=0)return;
   throw FileSystemException('Could not create checkout symbolic link',link,OSError('CreateSymbolicLinkW failed',lastError()));
  } finally {calloc.free(destination);calloc.free(source);}
 }
}
