import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/macho_linkedit_aligner.dart';

/// Builds a minimal 64-bit Mach-O carrying LC_SYMTAB + LC_DYSYMTAB laid out
/// the way `ld64.lld` emits it: the string table packed directly after an
/// indirect symbol table of [indirectCount] 4-byte entries.
///
/// [strings] is the string-table payload; a real linker ends it with NUL
/// padding, which is the slack the aligner consumes.
Uint8List buildMachO({required int indirectCount, required List<int> strings}) {
  const headerSize = 32;
  const symtabSize = 24;
  const dysymtabSize = 80;
  const commandsSize = symtabSize + dysymtabSize;
  const symtabOffset = headerSize;
  const dysymtabOffset = symtabOffset + symtabSize;

  // One 16-byte nlist_64 entry, then the indirect table, then the strings.
  const symbolOffset = headerSize + commandsSize;
  const indirectOffset = symbolOffset + 16;
  final stringsOffset = indirectOffset + indirectCount * 4;
  final total = stringsOffset + strings.length;

  final bytes = Uint8List(total);
  final data = ByteData.sublistView(bytes);

  data.setUint32(0, 0xFEED_FACF, Endian.little); // magic64
  data.setUint32(4, 0x0100_000c, Endian.little); // arm64
  data.setUint32(12, 0x6, Endian.little); // MH_DYLIB
  data.setUint32(16, 2, Endian.little); // ncmds
  data.setUint32(20, commandsSize, Endian.little);

  data.setUint32(symtabOffset, 0x2, Endian.little); // LC_SYMTAB
  data.setUint32(symtabOffset + 4, symtabSize, Endian.little);
  data.setUint32(symtabOffset + 8, symbolOffset, Endian.little);
  data.setUint32(symtabOffset + 12, 1, Endian.little); // nsyms
  data.setUint32(symtabOffset + 16, stringsOffset, Endian.little);
  data.setUint32(symtabOffset + 20, strings.length, Endian.little);

  data.setUint32(dysymtabOffset, 0x0b, Endian.little); // LC_DYSYMTAB
  data.setUint32(dysymtabOffset + 4, dysymtabSize, Endian.little);
  data.setUint32(dysymtabOffset + 56, indirectOffset, Endian.little);
  data.setUint32(dysymtabOffset + 60, indirectCount, Endian.little);

  // The single symbol points at string index 1, the first real name.
  data.setUint32(symbolOffset, 1, Endian.little);

  bytes.setRange(stringsOffset, total, strings);
  return bytes;
}

({int offset, int size}) readSymtab(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return (
    offset: data.getUint32(32 + 16, Endian.little),
    size: data.getUint32(32 + 20, Endian.little),
  );
}

/// `\0name\0` plus [padding] trailing NULs, as a linker would emit.
List<int> stringTable(String name, {required int padding}) => [
  0,
  ...name.codeUnits,
  0,
  ...List.filled(padding, 0),
];

void main() {
  group('MachOLinkeditAligner', () {
    test('realigns a 4-byte aligned string table without resizing', () {
      // An odd indirect count is what leaves stroff 4-byte aligned.
      final bytes = buildMachO(
        indirectCount: 171,
        strings: stringTable('_hello', padding: 8),
      );
      final before = readSymtab(bytes);
      expect(before.offset % 8, 4, reason: 'fixture must start misaligned');
      final originalLength = bytes.length;

      expect(MachOLinkeditAligner.alignBytes(bytes, source: 'fixture'), isTrue);

      final after = readSymtab(bytes);
      expect(after.offset % 8, 0);
      expect(after.offset, before.offset + 4);
      expect(after.size, before.size - 4);
      expect(bytes.length, originalLength, reason: 'must not resize the file');
    });

    test('keeps every symbol name resolvable at its original index', () {
      final bytes = buildMachO(
        indirectCount: 171,
        strings: stringTable('_hello', padding: 8),
      );
      MachOLinkeditAligner.alignBytes(bytes, source: 'fixture');

      // The single symbol still points at string index 1, which must still
      // spell the same name from the table's new offset.
      final symtab = readSymtab(bytes);
      final start = symtab.offset + 1;
      final end = bytes.indexOf(0, start);
      expect(String.fromCharCodes(bytes.sublist(start, end)), '_hello');
      expect(bytes[symtab.offset], 0, reason: 'index 0 stays the empty name');
    });

    test('leaves an already aligned table untouched', () {
      final bytes = buildMachO(
        indirectCount: 170, // even count keeps stroff 8-byte aligned
        strings: stringTable('_hello', padding: 8),
      );
      expect(readSymtab(bytes).offset % 8, 0);
      final copy = Uint8List.fromList(bytes);

      expect(
        MachOLinkeditAligner.alignBytes(bytes, source: 'fixture'),
        isFalse,
      );
      expect(bytes, copy);
    });

    test('refuses to shift when the tail is not linker padding', () {
      // No trailing NUL slack: shifting would truncate a real name.
      final bytes = buildMachO(
        indirectCount: 171,
        strings: stringTable('_hello', padding: 0),
      );
      final copy = Uint8List.fromList(bytes);

      expect(
        MachOLinkeditAligner.alignBytes(bytes, source: 'fixture'),
        isFalse,
      );
      expect(bytes, copy, reason: 'an unsafe file must be left alone');
    });

    test('retains the final symbol terminator inside the shortened table', () {
      final bytes = buildMachO(
        indirectCount: 171,
        strings: stringTable('_hello', padding: 3),
      );
      final copy = Uint8List.fromList(bytes);

      expect(
        MachOLinkeditAligner.alignBytes(bytes, source: 'fixture'),
        isFalse,
      );
      expect(bytes, copy, reason: 'three padding bytes are not enough');
    });

    test('leaves every already-aligned layout byte-identical', () {
      // Sweep the indirect-symbol counts a correct linker produces (Apple
      // ld64, and lld whenever the count happens to be even). None of these
      // may be touched: this repair must only ever fire on the broken shape.
      for (var indirectCount = 0; indirectCount <= 64; indirectCount += 2) {
        final bytes = buildMachO(
          indirectCount: indirectCount,
          strings: stringTable('_hello', padding: 8),
        );
        expect(
          readSymtab(bytes).offset % 8,
          0,
          reason: 'fixture with $indirectCount entries must start aligned',
        );
        final copy = Uint8List.fromList(bytes);

        expect(
          MachOLinkeditAligner.alignBytes(bytes, source: 'fixture'),
          isFalse,
          reason: 'aligned file with $indirectCount entries was modified',
        );
        expect(bytes, copy, reason: 'bytes changed for $indirectCount');
      }
    });

    test('ignores files that are not 64-bit Mach-O', () {
      final bytes = Uint8List.fromList(List.filled(64, 0x41));
      expect(
        MachOLinkeditAligner.alignBytes(bytes, source: 'fixture'),
        isFalse,
      );
    });
  });
}
