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

import '../loader/memory_allocator.dart';
import 'elf_reader.dart';

/// Resolves a symbol this library imports but does not define itself
/// (bionic libc functions, pthread stubs, dlopen/dlsym/dlclose, etc. —
/// see `native_symbol_stubs.dart`). Implementations must return
/// [nullptr] rather than a nullable value for unresolved symbols — see
/// the divergence note below.
typedef ExternalSymbolResolver = Pointer<Void> Function(String symbolName);

/// A manually loaded, manually relocated ELF64 shared object.
class ElfLoadedLibrary {
  ElfLoadedLibrary._(this._allocation, this._symtab, this._gnuHash, this._elfHash);

  final NativeMemoryBlock _allocation;
  final ElfDynamicSymbolTable? _symtab;
  final GnuHashTable? _gnuHash;
  final ElfHashTable? _elfHash;

  /// The base address this library was loaded at.
  Pointer<Void> get base => _allocation.pointer.cast();

  // ponytail: hardcoded 4 KiB page size. x86_64 hosts (the only hosts
  // that can execute the x86_64 machine code we're loading here) always
  // use 4 KiB pages. Upstream's page-size "shift" compensation, for
  // hosts whose native page size exceeds the ELF's assumed 4 KiB segment
  // alignment (e.g. 16 KiB-page aarch64 systems), is unreachable on our
  // target and was not ported. If this loader is ever extended to load
  // an aarch64 `.so`, port that logic from androidlibrary.d's `shift`
  // handling first.
  static const int _pageSize = 4096;
  static int _pageFloor(int n) => n & ~(_pageSize - 1);
  static int _pageCeil(int n) => (n + _pageSize - 1) & ~(_pageSize - 1);

  /// Loads and relocates the ELF64 shared object at [bytes].
  factory ElfLoadedLibrary.load(
    Uint8List bytes,
    NativeMemoryAllocator allocator,
    ExternalSymbolResolver resolveExternalSymbol,
  ) {
    final elf = ElfReader(bytes);

    var minVaddr = 1 << 62;
    var maxVaddr = 0;
    for (var i = 0; i < elf.ehPhnum; i++) {
      if (elf.phType(i) != elfPtLoad) continue;
      final start = elf.phVaddr(i);
      final end = start + elf.phMemsz(i);
      if (start < minVaddr) minVaddr = start;
      if (end > maxVaddr) maxVaddr = end;
    }

    final alignedMin = _pageFloor(minVaddr);
    final alignedMax = _pageCeil(maxVaddr);
    final allocation = allocator.alloc(alignedMax - alignedMin);

    for (var i = 0; i < elf.ehPhnum; i++) {
      if (elf.phType(i) != elfPtLoad) continue;

      final headerStart = elf.phVaddr(i) - alignedMin;
      final headerEnd = headerStart + elf.phFilesz(i);
      final memEnd = headerStart + elf.phMemsz(i);
      final fileStart = elf.phOffset(i);

      final protStart = _pageFloor(headerStart);
      final protLength = _pageCeil(memEnd) - protStart;

      // RW while we copy the segment's bytes in, matching upstream's
      // "protect RW, copy, protect final" two-step.
      allocator.protect(allocation,
          offset: protStart, length: protLength, readable: true, writable: true, executable: false);

      allocation.pointer
          .cast<Uint8>()
          .asTypedList(allocation.length)
          .setRange(headerStart, headerEnd, bytes, fileStart);

      final flags = elf.phFlags(i);
      allocator.protect(
        allocation,
        offset: protStart,
        length: protLength,
        readable: flags & elfPfR != 0,
        writable: flags & elfPfW != 0,
        executable: flags & elfPfX != 0,
      );
    }

    // Single linear pass over section headers, applying relocations
    // in-place as SHT_RELA sections are encountered — faithfully matching
    // upstream's ordering-dependent design (relocations are resolved
    // using whatever dynsym/dynstr/hash-table state has been seen *so
    // far* in file order, not a two-pass "parse everything, then
    // relocate" approach). This relies on the conventional toolchain
    // section ordering (.dynsym/.dynstr before .rela.*), same as
    // upstream does.
    int? symtabOffset;
    int? symtabCount;
    int? strtabOffset;
    GnuHashTable? gnuHash;
    ElfHashTable? elfHash;

    for (var i = 0; i < elf.ehShnum; i++) {
      final type = elf.shType(i);
      final offset = elf.shOffset(i);
      final size = elf.shSize(i);

      switch (type) {
        case elfShtDynsym:
          symtabOffset = offset;
          symtabCount = size ~/ ElfDynamicSymbolTable.symSize;
          break;
        case elfShtStrtab:
          if (elf.sectionName(i) == '.dynstr') {
            strtabOffset = offset;
          }
          break;
        case elfShtGnuHash:
          gnuHash = GnuHashTable(Uint8List.sublistView(bytes, offset, offset + size));
          break;
        case elfShtHash:
          // Matches upstream: only used if no (preferred) GNU hash table
          // has been seen yet.
          elfHash ??= ElfHashTable(Uint8List.sublistView(bytes, offset, offset + size));
          break;
        case elfShtRela:
          if (symtabOffset == null || strtabOffset == null) {
            throw StateError(
                'SHT_RELA section encountered before SHT_DYNSYM/.dynstr '
                'were seen; this loader assumes the conventional section '
                'order, matching upstream androidlibrary.d\'s same '
                'assumption.');
          }
          final symtab =
              ElfDynamicSymbolTable(elf.data, symtabOffset, symtabCount!, strtabOffset, bytes);
          _applyRelaSection(allocation, elf.data, offset, size, symtab, resolveExternalSymbol, alignedMin);
          break;
        case elfShtRel:
          throw StateError(
              'SHT_REL relocation section encountered; only SHT_RELA is '
              'supported here (x86_64 ELF objects always use RELA, never '
              'the legacy implicit-addend REL format).');
        default:
          break;
      }
    }

    final finalSymtab = (symtabOffset != null && strtabOffset != null)
        ? ElfDynamicSymbolTable(elf.data, symtabOffset, symtabCount!, strtabOffset, bytes)
        : null;

    return ElfLoadedLibrary._(allocation, finalSymtab, gnuHash, elfHash);
  }

  static void _applyRelaSection(
    NativeMemoryBlock allocation,
    ByteData elfData,
    int shOffset,
    int shSize,
    ElfDynamicSymbolTable symtab,
    ExternalSymbolResolver resolveExternalSymbol,
    int alignedMin,
  ) {
    final rela = ElfRelaTable(elfData, shOffset, shSize ~/ ElfRelaTable.relaSize);
    final base = allocation.pointer.address;

    for (var i = 0; i < rela.count; i++) {
      final type = rela.relocationType(i);
      final symbolIndex = rela.symbolIndex(i);
      final offset = rela.offset(i) - alignedMin;
      final addend = rela.addend(i);

      // Matches upstream: the referenced symbol is always resolved
      // up-front regardless of relocation type, even though RELATIVE
      // relocations (symbolIndex == 0, the null symbol entry) never
      // actually use the result.
      final resolvedAddress =
          symbolIndex == 0 ? 0 : resolveExternalSymbol(symtab.name(symbolIndex)).address;

      final target = (allocation.pointer + offset).cast<Uint64>();

      switch (type) {
        case rX8664Relative:
          target.value = base + addend;
          break;
        case rX8664GlobDat:
          target.value = resolvedAddress + addend;
          break;
        case rX8664JumpSlot:
          target.value = resolvedAddress;
          break;
        case rX8664Abs64:
          target.value = resolvedAddress + addend;
          break;
        default:
          throw StateError('Unknown x86_64 relocation type: $type');
      }
    }
  }

  /// Resolves an exported symbol to its loaded address. Ported from
  /// `AndroidLibrary.load(string symbolName)` in androidlibrary.d
  /// (upstream reuses `load` for both "resolve one of my own exports"
  /// and, confusingly, the ADI FFI wrapper's per-function lookups; this
  /// is the former — see `native_symbol_stubs.dart`'s dlsym emulation
  /// for the latter).
  Pointer<Void> lookup(String symbolName) {
    final symtab = _symtab;
    if (symtab == null) {
      throw StateError('Library has no dynamic symbol table.');
    }

    int? index;
    if (_gnuHash != null) {
      index = _gnuHash.lookup(symbolName, symtab);
    } else if (_elfHash != null) {
      index = _elfHash.lookup(symbolName, symtab);
    } else {
      for (var i = 0; i < symtab.count; i++) {
        if (symtab.name(i) == symbolName) {
          index = i;
          break;
        }
      }
    }

    if (index == null) {
      throw StateError('Symbol not found: $symbolName');
    }
    return (base.cast<Uint8>() + symtab.value(index)).cast();
  }
}
