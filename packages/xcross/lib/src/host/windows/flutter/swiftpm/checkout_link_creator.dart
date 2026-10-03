import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_link_creator.dart';

final class WindowsSwiftPmCheckoutLinkCreator
    implements SwiftPmCheckoutLinkCreator {
  const WindowsSwiftPmCheckoutLinkCreator({
    required this.fileSystem,
    required this.createLink,
    required this.lastError,
  });
  final SwiftPmArtifactFileSystem fileSystem;
  final int Function(String link, String target, int flags) createLink;
  final int Function() lastError;
  @override
  void create(String link, String target) {
    final resolved = p.isAbsolute(target)
        ? target
        : p.join(p.dirname(link), target);
    final flags = fileSystem.directory(resolved).existsSync() ? 1 : 0;
    if (createLink(p.absolute(link), target, flags | 2) != 0) return;
    if (createLink(p.absolute(link), target, flags) != 0) return;
    throw FileSystemException(
      'Could not create checkout symbolic link',
      link,
      OSError('CreateSymbolicLinkW failed', lastError()),
    );
  }
}

final class WindowsSwiftPmNativeLinkApi {
  WindowsSwiftPmNativeLinkApi(DynamicLibrary library)
    : _createLink = library
          .lookupFunction<
            Uint8 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
            int Function(Pointer<Utf16>, Pointer<Utf16>, int)
          >('CreateSymbolicLinkW'),
      lastError = library.lookupFunction<Uint32 Function(), int Function()>(
        'GetLastError',
      );
  final int Function(Pointer<Utf16>, Pointer<Utf16>, int) _createLink;
  final int Function() lastError;
  int createLink(String link, String target, int flags) {
    final destination = link.toNativeUtf16();
    final source = target.toNativeUtf16();
    try {
      return _createLink(destination, source, flags);
    } finally {
      calloc.free(destination);
      calloc.free(source);
    }
  }
}
