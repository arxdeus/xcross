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

// --- ELF64 constants (standard ELF/SysV AMD64 ABI values) ---

const int elfPtLoad = 1;

const int elfShtDynsym = 11;
const int elfShtStrtab = 3;
const int elfShtRel = 9;
const int elfShtRela = 4;
const int elfShtHash = 5;
const int elfShtGnuHash = 0x6ffffff6;

const int elfPfX = 1;
const int elfPfW = 2;
const int elfPfR = 4;

/// x86_64 relocation types upstream's `relocate()` handles (ported from
/// androidlibrary.d's `relocate()` switch: `R_GENERIC!"RELATIVE"`,
/// `R_GENERIC!"GLOB_DAT"`, `R_GENERIC!"JUMP_SLOT"`, and
/// `R_GENERIC_NATIVE_ABS` which for `version(X86_64)` upstream aliases to
/// `R_X86_64_64`). All four cases are present in the fetched source; the
/// task's framing only mentioned the first three, so the `R_X86_64_64`
/// case is called out explicitly in the port report.
const int rX8664Relative = 8;
const int rX8664GlobDat = 6;
const int rX8664JumpSlot = 7;
const int rX8664Abs64 = 1;

/// Reads ELF64 structures directly out of a raw file image (no `mmap` of
/// the *file itself* the way upstream's `MmFile` does — we just need the
/// bytes as a source buffer to copy segments out of, which
/// `File.readAsBytesSync()` provides just as well for that purpose).
class ElfReader {
  ElfReader(this.bytes) : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;

  // --- Ehdr ---
  int get ehPhoff => data.getUint64(32, Endian.little);
  int get ehShoff => data.getUint64(40, Endian.little);
  int get ehPhnum => data.getUint16(56, Endian.little);
  int get ehShnum => data.getUint16(60, Endian.little);
  int get ehShstrndx => data.getUint16(62, Endian.little);

  // --- Phdr (Elf64_Phdr, 56 bytes each) ---
  static const int _phdrSize = 56;
  int phType(int i) => data.getUint32(ehPhoff + i * _phdrSize, Endian.little);
  int phFlags(int i) => data.getUint32(ehPhoff + i * _phdrSize + 4, Endian.little);
  int phOffset(int i) => data.getUint64(ehPhoff + i * _phdrSize + 8, Endian.little);
  int phVaddr(int i) => data.getUint64(ehPhoff + i * _phdrSize + 16, Endian.little);
  int phFilesz(int i) => data.getUint64(ehPhoff + i * _phdrSize + 32, Endian.little);
  int phMemsz(int i) => data.getUint64(ehPhoff + i * _phdrSize + 40, Endian.little);

  // --- Shdr (Elf64_Shdr, 64 bytes each) ---
  static const int _shdrSize = 64;
  int shName(int i) => data.getUint32(ehShoff + i * _shdrSize, Endian.little);
  int shType(int i) => data.getUint32(ehShoff + i * _shdrSize + 4, Endian.little);
  int shOffset(int i) => data.getUint64(ehShoff + i * _shdrSize + 24, Endian.little);
  int shSize(int i) => data.getUint64(ehShoff + i * _shdrSize + 32, Endian.little);

  /// Name of section [i], read via the section-header string table
  /// (`e_shstrndx`).
  String sectionName(int i) {
    final strtabSectionOffset = shOffset(ehShstrndx);
    return _readCString(strtabSectionOffset + shName(i));
  }

  String _readCString(int offset) {
    var end = offset;
    while (bytes[end] != 0) {
      end++;
    }
    return String.fromCharCodes(bytes, offset, end);
  }
}

/// The ELF64 dynamic symbol table (`.dynsym`, paired with `.dynstr` for
/// names). Elf64_Sym is 24 bytes.
class ElfDynamicSymbolTable {
  ElfDynamicSymbolTable(this._data, this._offset, this.count, this._strtabOffset, this._bytes);

  static const int symSize = 24;

  final ByteData _data;
  final int _offset;
  final int count;
  final int _strtabOffset;
  final Uint8List _bytes;

  int value(int i) => _data.getUint64(_offset + i * symSize + 8, Endian.little);
  int _nameOffset(int i) => _data.getUint32(_offset + i * symSize, Endian.little);

  String name(int i) => _readCString(_strtabOffset + _nameOffset(i));

  String _readCString(int offset) {
    var end = offset;
    while (_bytes[end] != 0) {
      end++;
    }
    return String.fromCharCodes(_bytes, offset, end);
  }
}

/// ELF64 RELA relocation records (Elf64_Rela, 24 bytes each; explicit
/// addend). x86_64 ELF objects only ever use RELA, never the legacy
/// implicit-addend REL format.
class ElfRelaTable {
  ElfRelaTable(this._data, this._offset, this.count);

  static const int relaSize = 24;

  final ByteData _data;
  final int _offset;
  final int count;

  int offset(int i) => _data.getUint64(_offset + i * relaSize, Endian.little);
  int _info(int i) => _data.getUint64(_offset + i * relaSize + 8, Endian.little);
  int addend(int i) => _data.getInt64(_offset + i * relaSize + 16, Endian.little);

  /// `ELF64_R_SYM(r_info)`.
  int symbolIndex(int i) => _info(i) >> 32;

  /// `ELF64_R_TYPE(r_info)`.
  int relocationType(int i) => _info(i) & 0xffffffff;
}

/// SysV ELF `.hash` symbol lookup. Ported from `ElfHashTable` in
/// androidlibrary.d.
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

  int _bucket(int i) => _data.getUint32(_bucketsOffset + i * 4, Endian.little);
  int _chain(int i) => _data.getUint32(_chainOffset + i * 4, Endian.little);

  static int hash(String name) {
    var h = 0;
    for (final c in name.codeUnits) {
      h = (16 * h + c) & 0xffffffff;
      h ^= (h >> 24) & 0xf0;
    }
    return h & 0xfffffff;
  }

  /// Returns the resolved symbol index, or `null` if not found.
  int? lookup(String symbolName, ElfDynamicSymbolTable symtab) {
    final targetHash = hash(symbolName);
    for (var i = _bucket(targetHash % _nbucket); i != 0; i = _chain(i)) {
      if (symtab.name(i) == symbolName) return i;
    }
    return null;
  }
}

/// GNU `.gnu.hash` symbol lookup. Ported from `GnuHashTable` in
/// androidlibrary.d.
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

  int _bucket(int i) => _data.getUint32(_bucketsOffset + i * 4, Endian.little);
  int _chain(int i) => _data.getUint32(_chainOffset + i * 4, Endian.little);

  static int hash(String name) {
    var h = 5381;
    for (final c in name.codeUnits) {
      h = ((h << 5) + h + c) & 0xffffffff;
    }
    return h;
  }

  /// Returns the resolved symbol index, or `null` if not found.
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
}
