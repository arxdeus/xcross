import 'dart:io';

import 'package:xcross/src/errors.dart';

abstract final class MachOValidator {
  static const _littleEndian64Magic = [0xcf, 0xfa, 0xed, 0xfe];
  static const _bigEndian64Magic = [0xfe, 0xed, 0xfa, 0xcf];

  static void validate64BitExecutable(String path) {
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() < 32) {
      throw XcrossError('Runner Mach-O output is incomplete or missing: $path');
    }
    final handle = file.openSync()..setPositionSync(0);
    try {
      final header = handle.readSync(32);
      final magic = header.take(4).toList(growable: false);
      if (!_matchesMagic(magic, _littleEndian64Magic) &&
          !_matchesMagic(magic, _bigEndian64Magic)) {
        throw XcrossError(
          'Runner output is not a complete 64-bit Mach-O: $path',
        );
      }
    } finally {
      handle.closeSync();
    }
  }

  static bool _matchesMagic(List<int> actual, List<int> expected) {
    for (var i = 0; i < expected.length; i++) {
      if (actual[i] != expected[i]) return false;
    }
    return true;
  }
}
