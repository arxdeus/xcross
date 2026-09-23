import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:xcross/src/apple/mach_o.dart';
import 'package:xcross/src/flutter/errors.dart';

/// Repairs Mach-O symbol tables whose string table is not 8-byte aligned.
///
/// `ld64.lld` packs `LC_SYMTAB.stroff` directly after the indirect symbol
/// table without padding. That table holds 4-byte entries, so an odd symbol
/// count leaves `stroff` 4-byte aligned. Apple's linker always pads to 8, and
/// dyld on iOS 26 enforces it: loading such a library fails the whole app with
///
///     mis-aligned LINKEDIT string pool, fileOffset=0x...
///
/// which surfaces to the user as a Dart `Failed to load dynamic library` and a
/// black screen, with nothing naming the real cause.
///
/// The repair slides the string table forward by the few bytes needed and
/// shortens it by the same amount, consuming the run of NUL padding the
/// linker leaves at the end. Byte `stroff + i` becomes `newStroff + i`, so
/// every `n_strx` index in the symbol table still resolves to its original
/// name and the file keeps its exact length: no offset outside the string
/// table moves, and nothing else has to be rewritten.
///
/// Must run before code signing, so the signature covers the repaired bytes.
abstract final class MachOLinkeditAligner {
  /// `LC_DYSYMTAB` — locates the indirect symbol table.
  static const _dysymtab = 0x0b;

  /// Apple's alignment for the LINKEDIT string pool.
  static const _stringTableAlignment = 8;

  /// Aligns the string table of [path] when it needs it.
  ///
  /// Returns true when the file was rewritten. A file that is already aligned,
  /// or that cannot be repaired safely, is left untouched.
  static Future<bool> alignFile(String path) async {
    final file = File(path);
    if (!file.existsSync()) return false;
    final bytes = await file.readAsBytes();
    if (!alignBytes(bytes, source: path)) return false;
    await file.writeAsBytes(bytes, flush: true);
    return true;
  }

  /// Aligns the string table inside [bytes] in place.
  ///
  /// Returns true when [bytes] were modified.
  @visibleForTesting
  static bool alignBytes(Uint8List bytes, {required String source}) {
    if (!_isMachO64(bytes)) return false;
    final file = MachOFile.parse(
      bytes,
      invalid: (message) => _invalid(source, message),
    );

    MachOLoadCommand? symtab;
    for (final command in file.commands) {
      if (command.type == MachOConstants.lcSymtab) symtab = command;
    }
    if (symtab == null) return false;
    if (symtab.size < 24) {
      file.invalid('LC_SYMTAB is shorter than 24 bytes');
    }

    final stringsOffset = file.data.getUint32(
      symtab.offset + 16,
      Endian.little,
    );
    final stringsSize = file.data.getUint32(symtab.offset + 20, Endian.little);
    final padding =
        (_stringTableAlignment - (stringsOffset % _stringTableAlignment)) %
        _stringTableAlignment;
    if (padding == 0) return false;
    if (!MachOFile.rangeFits(stringsOffset, stringsSize, bytes.length)) {
      file.invalid('LC_SYMTAB string table exceeds file bounds');
    }
    if (stringsSize <= padding) return false;

    // The shift is only lossless if the bytes it drops are the linker's own
    // NUL padding. Anything else would be a name a symbol still points at.
    final tailStart = stringsOffset + stringsSize - padding;
    for (
      var offset = tailStart;
      offset < stringsOffset + stringsSize;
      offset++
    ) {
      if (bytes[offset] != 0) return false;
    }
    // At least one terminator must remain inside the shortened table. With
    // only three padding bytes, the fourth removed NUL ends the final name.
    if (bytes[tailStart - 1] != 0) return false;

    // Nothing may live between the indirect symbol table and the strings, or
    // sliding the strings forward would overwrite it.
    if (!_indirectTableEndsAt(file, stringsOffset)) return false;

    bytes.setRange(
      stringsOffset + padding,
      stringsOffset + stringsSize,
      bytes.sublist(stringsOffset, tailStart),
    );
    bytes.fillRange(stringsOffset, stringsOffset + padding, 0);

    file.data.setUint32(
      symtab.offset + 16,
      stringsOffset + padding,
      Endian.little,
    );
    file.data.setUint32(
      symtab.offset + 20,
      stringsSize - padding,
      Endian.little,
    );
    return true;
  }

  /// Whether the indirect symbol table ends exactly where the strings begin.
  ///
  /// This is the layout that produces the misalignment, and the only one where
  /// the gap being claimed is known to belong to nobody. A file without
  /// `LC_DYSYMTAB` has no indirect table to collide with.
  static bool _indirectTableEndsAt(MachOFile file, int stringsOffset) {
    for (final command in file.commands) {
      if (command.type != _dysymtab) continue;
      if (command.size < 80) {
        file.invalid('LC_DYSYMTAB is shorter than 80 bytes');
      }
      final indirectOffset = file.data.getUint32(
        command.offset + 56,
        Endian.little,
      );
      final indirectCount = file.data.getUint32(
        command.offset + 60,
        Endian.little,
      );
      if (indirectOffset == 0 || indirectCount == 0) return true;
      return indirectOffset + indirectCount * 4 == stringsOffset;
    }
    return true;
  }

  static bool _isMachO64(Uint8List bytes) {
    if (bytes.length < MachOConstants.headerSize64) return false;
    return ByteData.sublistView(bytes).getUint32(0, Endian.little) ==
        MachOConstants.magic64;
  }

  static Never _invalid(String source, String message) =>
      throw FlutterBuildError('$source: invalid Mach-O: $message');
}
