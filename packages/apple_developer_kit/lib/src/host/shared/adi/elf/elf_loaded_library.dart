// Ported from `AndroidLibrary` in Provision's
// lib/provision/androidlibrary.d (https://github.com/Dadoum/Provision,
// LGPLv2 — see LICENSE/NOTICE.md).
//
// This does NOT use the OS's dynamic linker (`dlopen`) at all: it mmaps a
// private RW region, copies each `PT_LOAD` segment's bytes into place,
// applies `SHT_RELA` relocations by hand (resolving imported symbols
// against an injected [ExternalSymbolResolver] instead of the host libc),
// then flips each segment to its final protection. This is what makes it
// safe to load Android/bionic-targeted `.so` files on a glibc host:
// bionic-specific symbols (notably the `pthread_*` family, whose struct
// layouts differ from glibc's — bionic's `pthread_mutex_t` is 4 bytes,
// glibc's is ~40) never touch the real glibc implementations. A plain
// `dlopen()` would resolve those same-named symbols to the real glibc
// functions, which then write into a struct sized for 4 bytes as if it
// were ~40 — silent heap/stack corruption. See NOTICE.md.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/host/shared/adi/elf/elf_code_preparation.dart';
import 'package:apple_developer_kit/src/host/shared/adi/loader/internal/memory_allocator.dart';
import 'package:apple_developer_kit/src/shared/adi/elf/elf_reader.dart';
import 'package:meta/meta.dart';

@internal
typedef ExternalSymbolResolver = Pointer<Void> Function(String symbolName);

@internal
class ElfLoadedLibrary {
  ElfLoadedLibrary._(this._allocation, this._bias, this._symtab);

  factory ElfLoadedLibrary.load(
    Uint8List bytes,
    NativeMemoryAllocator allocator,
    ExternalSymbolResolver resolveExternalSymbol, {
    required int machine,
    required ElfCodePreparation codePreparation,
  }) {
    final elf = ElfReader(bytes);
    elf.validate(machine: machine);
    final codeRegions = [
      for (final section in elf.validateExecutableSections())
        (elf.shAddr(section), elf.shSize(section)),
    ];
    final pageSize = allocator.pageSize;
    if (pageSize < 4096 || pageSize & (pageSize - 1) != 0) {
      throw StateError('Unsupported host page size: $pageSize');
    }
    final segments = [
      for (var i = 0; i < elf.ehPhnum; i++)
        if (elf.phType(i) == ElfSegmentType.load && elf.phMemsz(i) != 0) i,
    ];
    if (segments.isEmpty) throw const FormatException('ELF has no image.');
    final min =
        segments.map(elf.phVaddr).reduce((a, b) => a < b ? a : b) &
        ~(pageSize - 1);
    final max = segments
        .map((i) => elf.phVaddr(i) + elf.phMemsz(i))
        .reduce((a, b) => a > b ? a : b);
    Map<int, int>? protections;
    var shift = 0;
    for (; shift < pageSize; shift += 4096) {
      final pages = <int, int>{};
      for (final i in segments) {
        final start = (elf.phVaddr(i) - min + shift) & ~(pageSize - 1);
        final end =
            (elf.phVaddr(i) + elf.phMemsz(i) - min + shift + pageSize - 1) &
            ~(pageSize - 1);
        for (var page = start; page < end; page += pageSize) {
          pages[page] = (pages[page] ?? 0) | elf.phFlags(i);
        }
      }
      if (pages.values.every((flags) => flags & 3 != 3)) {
        protections = pages;
        break;
      }
    }
    if (protections == null) {
      throw UnsupportedError(
        'ELF cannot preserve W^X with $pageSize-byte host pages.',
      );
    }
    final length = (max - min + shift + pageSize - 1) & ~(pageSize - 1);
    final allocation = allocator.alloc(length);
    final bias = allocation.pointer.address + shift - min;
    try {
      final memory = allocation.pointer.asTypedList(length);
      memory.fillRange(0, length, 0);
      for (final i in segments) {
        final start = shift + elf.phVaddr(i) - min;
        memory.setRange(start, start + elf.phFilesz(i), bytes, elf.phOffset(i));
      }
      ElfDynamicSymbolTable? symbols;
      for (var i = 0; i < elf.ehShnum; i++) {
        if (elf.shType(i) != ElfSectionType.dynamicSymbols) continue;
        final link = elf.data.getUint32(
          elf.ehShoff + i * 64 + 40,
          Endian.little,
        );
        if (link >= elf.ehShnum ||
            elf.shType(link) != ElfSectionType.stringTable ||
            elf.shSize(i) % ElfDynamicSymbolTable.symSize != 0) {
          throw const FormatException('Invalid ELF dynamic symbol table.');
        }
        symbols = ElfDynamicSymbolTable(
          data: elf.data,
          offset: elf.shOffset(i),
          count: elf.shSize(i) ~/ ElfDynamicSymbolTable.symSize,
          stringTableOffset: elf.shOffset(link),
          bytes: bytes,
        );
      }
      if (symbols == null) {
        throw const FormatException('ELF has no dynamic symbols.');
      }
      for (var i = 1; i < symbols.count; i++) {
        final section = symbols.sectionIndex(i);
        if (section == 0 || section == 0xfff1) continue;
        final value = symbols.value(i);
        if (section >= elf.ehShnum ||
            !segments.any(
              (segment) =>
                  value >= elf.phVaddr(segment) &&
                  value <= elf.phVaddr(segment) + elf.phMemsz(segment),
            )) {
          throw const FormatException(
            'ELF symbol is outside the loaded image.',
          );
        }
      }
      final arm64 = elf.machine == 183;
      for (var section = 0; section < elf.ehShnum; section++) {
        final sectionType = elf.shType(section);
        if (sectionType == ElfSectionType.rel ||
            sectionType == 19 ||
            sectionType == 0x60000001 ||
            sectionType == 0x60000002 ||
            sectionType == 0x6fffff00) {
          throw UnsupportedError(
            'Unsupported ELF relocation section: $sectionType',
          );
        }
        if (sectionType != ElfSectionType.rela) continue;
        if (elf.shSize(section) % ElfRelaTable.relaSize != 0) {
          throw const FormatException('Invalid ELF RELA size.');
        }
        final rela = ElfRelaTable(
          elf.data,
          elf.shOffset(section),
          elf.shSize(section) ~/ ElfRelaTable.relaSize,
        );
        for (var i = 0; i < rela.count; i++) {
          final type = rela.relocationType(i);
          if (type == 0) continue;
          final relative = type == (arm64 ? 1027 : 8);
          final absolute = type == (arm64 ? 257 : 1);
          final global = type == (arm64 ? 1025 : 6);
          final jump = type == (arm64 ? 1026 : 7);
          if (!relative && !absolute && !global && !jump) {
            throw UnsupportedError(
              'Unsupported ELF machine ${elf.machine} relocation: $type',
            );
          }
          final address = rela.offset(i);
          if (address % 8 != 0 ||
              !segments.any(
                (s) =>
                    address >= elf.phVaddr(s) &&
                    address <= elf.phVaddr(s) + elf.phMemsz(s) - 8,
              )) {
            throw const FormatException(
              'ELF relocation target is outside a load segment or unaligned.',
            );
          }
          final index = rela.symbolIndex(i);
          if (index >= symbols.count || (relative && index != 0)) {
            throw const FormatException('Invalid ELF relocation symbol.');
          }
          var resolved = 0;
          if (!relative && index != 0) {
            final sectionIndex = symbols.sectionIndex(index);
            resolved = sectionIndex == 0
                ? resolveExternalSymbol(symbols.name(index)).address
                : symbols.value(index) + (sectionIndex == 0xfff1 ? 0 : bias);
          }
          Pointer<Uint64>.fromAddress(bias + address).value = relative
              ? bias + rela.addend(i)
              : resolved + ((jump || global) && !arm64 ? 0 : rela.addend(i));
        }
      }
      for (final (address, size) in codeRegions) {
        codePreparation.prepare(
          Pointer<Uint8>.fromAddress(bias + address),
          size,
        );
      }
      allocator.flushInstructionCache(allocation);
      for (var page = 0; page < length; page += pageSize) {
        final flags = protections[page] ?? 0;
        allocator.protect(
          allocation,
          offset: page,
          length: pageSize,
          readable: flags & 4 != 0,
          writable: flags & 2 != 0,
          executable: flags & 1 != 0,
        );
      }
      return ElfLoadedLibrary._(allocation, bias, symbols);
    } catch (_) {
      allocator.free(allocation);
      rethrow;
    }
  }

  final NativeMemoryBlock _allocation;
  final int _bias;
  final ElfDynamicSymbolTable _symtab;

  Pointer<Void> get base => _allocation.pointer.cast();

  @useResult
  Pointer<Void> lookup(String symbolName) {
    for (var i = 1; i < _symtab.count; i++) {
      if (_symtab.sectionIndex(i) != 0 && _symtab.name(i) == symbolName) {
        return Pointer<Void>.fromAddress(
          (_symtab.sectionIndex(i) == 0xfff1 ? 0 : _bias) + _symtab.value(i),
        );
      }
    }
    throw StateError('Symbol not found: $symbolName');
  }
}
