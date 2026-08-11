import 'dart:io';
import 'dart:typed_data';

import 'package:xcross/src/errors.dart';

abstract final class MachOValidator {
  static void validate64BitExecutable(String path) {
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() < 32) {
      throw XcrossError('Runner Mach-O output is incomplete or missing: $path');
    }
    final handle = file.openSync()..setPositionSync(0);
    try {
      final data = ByteData.sublistView(
        Uint8List.fromList(handle.readSync(32)),
      );
      final magic = data.getUint32(0);
      if (magic != 0xfeedfacf) {
        throw XcrossError(
          'Runner output is not a complete 64-bit Mach-O: $path',
        );
      }
    } finally {
      handle.closeSync();
    }
  }
}
