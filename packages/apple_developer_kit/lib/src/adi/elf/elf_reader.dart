// Struct layouts and relocation-type numeric values used to parse the
// ELF64 shared objects loaded by `ElfLoadedLibrary` (see
// elf_loaded_library.dart, ported from Provision's
// lib/provision/androidlibrary.d — https://github.com/Dadoum/Provision,
// LGPLv2, see LICENSE/NOTICE.md).
//
// Provision's own D source only references these via a vendored
// third-party ELF binding (`std_edit.elf`/`std_edit.link`, not part of
// Provision itself and not fetched for this port) by symbolic name
// (`ElfW!"Ehdr"`, `R_X86_64_RELATIVE`, etc.) — it never spells out the
// literal numeric values. The values below are the standard, publicly
// documented ELF64 / System V AMD64 ABI definitions (the same values
// found in glibc's/musl's elf.h), not something re-derived from
// Provision's own code. See NOTICE.md.
//
// Only what's needed for our x86_64 shared objects is implemented: ELF64
// header / program header / section header / dynamic-symbol parsing, and
// SHT_RELA relocation records. x86_64 ELF objects exclusively use RELA
// (explicit-addend) relocations, never legacy REL — see
// elf_loaded_library.dart for what happens if a REL section is ever
// encountered.

import 'dart:typed_data';

import 'package:meta/meta.dart';

/// `p_type` values of an ELF64 program header.
@internal
abstract final class ElfSegmentType {
  /// `PT_LOAD` — a segment the loader must map into memory.
  static const int load = 1;
}

/// `p_flags` bits of an ELF64 program header.
@internal
abstract final class ElfSegmentFlags {
  /// `PF_X`
  static const int execute = 1;

  /// `PF_W`
  static const int write = 2;

  /// `PF_R`
  static const int read = 4;
}

/// `sh_type` values of an ELF64 section header.
@internal
abstract final class ElfSectionType {
  /// `SHT_STRTAB`
  static const int stringTable = 3;

  /// `SHT_RELA` — relocations with an explicit addend.
  static const int rela = 4;

  /// `SHT_HASH` — SysV symbol hash table.
  static const int hash = 5;

  /// `SHT_REL` — legacy relocations with an implicit addend. Never
  /// emitted for x86_64.
  static const int rel = 9;

  /// `SHT_DYNSYM`
  static const int dynamicSymbols = 11;

  /// `SHT_GNU_HASH`
  static const int gnuHash = 0x6fff_fff6;
}

/// x86_64 relocation types upstream's `relocate()` handles (ported from
/// androidlibrary.d's `relocate()` switch: `R_GENERIC!"RELATIVE"`,
/// `R_GENERIC!"GLOB_DAT"`, `R_GENERIC!"JUMP_SLOT"`, and
/// `R_GENERIC_NATIVE_ABS` which for `version(X86_64)` upstream aliases to
/// `R_X86_64_64`). All four cases are present in the fetched source; the
/// task's framing only mentioned the first three, so the `R_X86_64_64`
/// case is called out explicitly in the port report.
@internal
abstract final class ElfRelocationType {
  /// `R_X86_64_64`
  static const int abs64 = 1;

  /// `R_X86_64_GLOB_DAT`
  static const int globalData = 6;

  /// `R_X86_64_JUMP_SLOT`
  static const int jumpSlot = 7;

  /// `R_X86_64_RELATIVE`
  static const int relative = 8;
}

/// Reads a NUL-terminated string out of [bytes] starting at [offset].
String _readCString(Uint8List bytes, int offset) {
  var end = offset;
  while (bytes[end] != 0) {
    end++;
  }
  return String.fromCharCodes(bytes, offset, end);
}

/// Reads ELF64 structures directly out of a raw file image (no `mmap` of
/// the *file itself* the way upstream's `MmFile` does — we just need the
/// bytes as a source buffer to copy segments out of, which
/// `File.readAsBytesSync()` provides just as well for that purpose).
@internal
@immutable
class ElfReader {
  ElfReader(this.bytes) : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;

  // --- Ehdr (Elf64_Ehdr) ---
  int get ehPhoff => data.getUint64(32, Endian.little);
  int get ehShoff => data.getUint64(40, Endian.little);
  int get ehPhnum => data.getUint16(56, Endian.little);
  int get ehShnum => data.getUint16(60, Endian.little);
  int get ehShstrndx => data.getUint16(62, Endian.little);

  // --- Phdr (Elf64_Phdr, 56 bytes each) ---
  static const int _phdrSize = 56;
  int phType(int i) => data.getUint32(ehPhoff + i * _phdrSize, Endian.little);
  int phFlags(int i) =>
      data.getUint32(ehPhoff + i * _phdrSize + 4, Endian.little);
  int phOffset(int i) =>
      data.getUint64(ehPhoff + i * _phdrSize + 8, Endian.little);
  int phVaddr(int i) =>
      data.getUint64(ehPhoff + i * _phdrSize + 16, Endian.little);
  int phFilesz(int i) =>
      data.getUint64(ehPhoff + i * _phdrSize + 32, Endian.little);
  int phMemsz(int i) =>
      data.getUint64(ehPhoff + i * _phdrSize + 40, Endian.little);

  // --- Shdr (Elf64_Shdr, 64 bytes each) ---
  static const int _shdrSize = 64;
  int shName(int i) => data.getUint32(ehShoff + i * _shdrSize, Endian.little);
  int shType(int i) =>
      data.getUint32(ehShoff + i * _shdrSize + 4, Endian.little);
  int shOffset(int i) =>
      data.getUint64(ehShoff + i * _shdrSize + 24, Endian.little);
  int shSize(int i) =>
      data.getUint64(ehShoff + i * _shdrSize + 32, Endian.little);

  /// Name of section [i], read via the section-header string table
  /// (`e_shstrndx`).
  String sectionName(int i) =>
      _readCString(bytes, shOffset(ehShstrndx) + shName(i));
}

/// The ELF64 dynamic symbol table (`.dynsym`, paired with `.dynstr` for
/// names). Elf64_Sym is 24 bytes.
@internal
@immutable
class ElfDynamicSymbolTable {
  const ElfDynamicSymbolTable({
    required ByteData data,
    required int offset,
    required this.count,
    required int stringTableOffset,
    required Uint8List bytes,
  }) : _data = data,
       _offset = offset,
       _stringTableOffset = stringTableOffset,
       _bytes = bytes;

  static const int symSize = 24;

  final ByteData _data;
  final int _offset;
  final int count;
  final int _stringTableOffset;
  final Uint8List _bytes;

  /// `st_value` — the symbol's address, relative to the load base.
  int value(int i) => _data.getUint64(_offset + i * symSize + 8, Endian.little);

  /// `st_name` resolved against `.dynstr`.
  String name(int i) =>
      _readCString(_bytes, _stringTableOffset + _nameOffset(i));

  int _nameOffset(int i) =>
      _data.getUint32(_offset + i * symSize, Endian.little);
}

/// ELF64 RELA relocation records (Elf64_Rela, 24 bytes each; explicit
/// addend). x86_64 ELF objects only ever use RELA, never the legacy
/// implicit-addend REL format.
@internal
@immutable
class ElfRelaTable {
  const ElfRelaTable(this._data, this._offset, this.count);

  static const int relaSize = 24;

  final ByteData _data;
  final int _offset;
  final int count;

  int offset(int i) => _data.getUint64(_offset + i * relaSize, Endian.little);
  int addend(int i) =>
      _data.getInt64(_offset + i * relaSize + 16, Endian.little);

  /// `ELF64_R_SYM(r_info)`.
  int symbolIndex(int i) => _info(i) >> 32;

  /// `ELF64_R_TYPE(r_info)`.
  int relocationType(int i) => _info(i) & 0xffff_ffff;

  int _info(int i) =>
      _data.getUint64(_offset + i * relaSize + 8, Endian.little);
}

/// SysV ELF `.hash` symbol lookup. Ported from `ElfHashTable` in
/// androidlibrary.d.
@internal
@immutable
class ElfHashTable {
  ElfHashTable(Uint8List table) : _data = ByteData.sublistView(table) {
    _nbucket = _data.getUint32(0, Endian.little);
    _bucketsOffset = 8;
    _chainOffset = _bucketsOffset + _nbucket * 4;
  }

  final ByteData _data;
  late final int _nbucket;
  late final int _bucketsOffset;
  late final int _chainOffset;

  @useResult
  static int hash(String name) {
    var h = 0;
    for (final c in name.codeUnits) {
      h = (16 * h + c) & 0xffff_ffff;
      h ^= (h >> 24) & 0xf0;
    }
    return h & 0xfff_ffff;
  }

  /// Returns the resolved symbol index, or `null` if not found.
  @useResult
  int? lookup(String symbolName, ElfDynamicSymbolTable symtab) {
    final targetHash = hash(symbolName);
    for (var i = _bucket(targetHash % _nbucket); i != 0; i = _chain(i)) {
      if (symtab.name(i) == symbolName) return i;
    }
    return null;
  }

  int _bucket(int i) => _data.getUint32(_bucketsOffset + i * 4, Endian.little);
  int _chain(int i) => _data.getUint32(_chainOffset + i * 4, Endian.little);
}

/// GNU `.gnu.hash` symbol lookup. Ported from `GnuHashTable` in
/// androidlibrary.d.
@internal
@immutable
class GnuHashTable {
  GnuHashTable(Uint8List table) : _data = ByteData.sublistView(table) {
    _nbuckets = _data.getUint32(0, Endian.little);
    _symoffset = _data.getUint32(4, Endian.little);
    final bloomSize = _data.getUint32(8, Endian.little);
    // Header is 4 uint32 fields (nbuckets, symoffset, bloomSize,
    // bloomShift) = 16 bytes; bloom words are native (8-byte) words on
    // x86_64, matching D's `size_t.sizeof`.
    const headerSize = 16;
    _bucketsOffset = headerSize + bloomSize * 8;
    _chainOffset = _bucketsOffset + _nbuckets * 4;
  }

  final ByteData _data;
  late final int _nbuckets;
  late final int _symoffset;
  late final int _bucketsOffset;
  late final int _chainOffset;

  @useResult
  static int hash(String name) {
    var h = 5381;
    for (final c in name.codeUnits) {
      h = ((h << 5) + h + c) & 0xffff_ffff;
    }
    return h;
  }

  /// Returns the resolved symbol index, or `null` if not found.
  @useResult
  int? lookup(String symbolName, ElfDynamicSymbolTable symtab) {
    var targetHash = hash(symbolName);
    final bucket = _bucket(targetHash % _nbuckets);
    if (bucket < _symoffset) return null;

    targetHash &= ~1;
    var symbolIndex = bucket;
    var chainIndex = bucket - _symoffset;
    while (true) {
      final h = _chain(chainIndex);
      if ((h & ~1) == targetHash && symtab.name(symbolIndex) == symbolName) {
        return symbolIndex;
      }
      if (h & 1 != 0) return null;
      chainIndex++;
      symbolIndex++;
    }
  }

  int _bucket(int i) => _data.getUint32(_bucketsOffset + i * 4, Endian.little);
  int _chain(int i) => _data.getUint32(_chainOffset + i * 4, Endian.little);
}
