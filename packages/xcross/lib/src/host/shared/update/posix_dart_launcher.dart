import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

final class PosixDartLauncher {
  PosixDartLauncher() : _access = _lookupAccess();
  final int Function(Pointer<Utf8>, int)? _access;

  bool accept(String path) {
    if (p.posix.basename(path) != 'dart') return false;
    final stat = FileStat.statSync(path);
    if (stat.type != FileSystemEntityType.file) return false;
    final access = _access;
    if (access == null) return stat.mode & 0x49 != 0;
    return using(
      (arena) => access(path.toNativeUtf8(allocator: arena), 1) == 0,
    );
  }

  static int Function(Pointer<Utf8>, int)? _lookupAccess() {
    final library = DynamicLibrary.process();
    if (!library.providesSymbol('access')) return null;
    return library.lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32),
      int Function(Pointer<Utf8>, int)
    >('access');
  }
}
