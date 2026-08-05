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

import 'package:apple_developer_kit/src/adi/elf/elf_reader.dart';
import 'package:apple_developer_kit/src/adi/loader/memory_allocator.dart';
import 'package:meta/meta.dart';

/// Resolves a symbol this library imports but does not define itself
/// (bionic libc functions, pthread stubs, dlopen/dlsym/dlclose, etc. —
/// see `native_symbol_stubs.dart`). Implementations must return
/// [nullptr] rather than a nullable value for unresolved symbols — see
/// the divergence note below.
@internal
typedef ExternalSymbolResolver = Pointer<Void> Function(String symbolName);

/// The reserved image a library's `PT_LOAD` segments are mapped into,
/// plus the page-aligned lowest `p_vaddr` every offset is relative to.
typedef _Image = ({NativeMemoryBlock allocation, int baseVaddr});

/// A page-aligned protection range within an [_Image].
typedef _PageRange = ({int offset, int length});

/// The symbol-lookup state collected while scanning section headers.
typedef _SymbolTables = ({
  ElfDynamicSymbolTable? symtab,
  GnuHashTable? gnuHash,
  ElfHashTable? elfHash,
});

/// A manually loaded, manually relocated ELF64 shared object.
@internal
@immutable
class ElfLoadedLibrary {
  const ElfLoadedLibrary._(
    this._allocation,
    this._symtab,
    this._gnuHash,
    this._elfHash,
  );

  /// Loads and relocates the ELF64 shared object at [bytes].
  factory ElfLoadedLibrary.load(
    Uint8List bytes,
    NativeMemoryAllocator allocator,
    ExternalSymbolResolver resolveExternalSymbol,
  ) {
    final elf = ElfReader(bytes);
    final image = _reserveImage(elf, allocator);
    _copySegments(elf, bytes, allocator, image);
    final tables = _relocate(
      elf,
      bytes,
      allocator,
      image,
      resolveExternalSymbol,
    );
    _applyFinalProtection(elf, allocator, image);

    return ElfLoadedLibrary._(
      image.allocation,
      tables.symtab,
      tables.gnuHash,
      tables.elfHash,
    );
  }

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

  /// Reserves one contiguous, page-aligned region spanning every
  /// `PT_LOAD` segment's `[p_vaddr, p_vaddr + p_memsz)`.
  static _Image _reserveImage(ElfReader elf, NativeMemoryAllocator allocator) {
    var minVaddr = 1 << 62;
    var maxVaddr = 0;
    for (var i = 0; i < elf.ehPhnum; i++) {
      if (elf.phType(i) != ElfSegmentType.load) continue;
      final start = elf.phVaddr(i);
      final end = start + elf.phMemsz(i);
      if (start < minVaddr) minVaddr = start;
      if (end > maxVaddr) maxVaddr = end;
    }

    final alignedMin = _pageFloor(minVaddr);
    final alignedMax = _pageCeil(maxVaddr);
    return (
      allocation: allocator.alloc(alignedMax - alignedMin),
      baseVaddr: alignedMin,
    );
  }

  /// The page-aligned range covering segment [i]'s whole `p_memsz`.
  static _PageRange _segmentPages(ElfReader elf, int i, int baseVaddr) {
    final headerStart = elf.phVaddr(i) - baseVaddr;
    final memEnd = headerStart + elf.phMemsz(i);
    final protStart = _pageFloor(headerStart);
    return (offset: protStart, length: _pageCeil(memEnd) - protStart);
  }

  static void _protect(
    NativeMemoryAllocator allocator,
    _Image image,
    _PageRange pages, {
    required bool readable,
    required bool writable,
    required bool executable,
  }) {
    allocator.protect(
      image.allocation,
      offset: pages.offset,
      length: pages.length,
      readable: readable,
      writable: writable,
      executable: executable,
    );
  }

  static void _copySegments(
    ElfReader elf,
    Uint8List bytes,
    NativeMemoryAllocator allocator,
    _Image image,
  ) {
    for (var i = 0; i < elf.ehPhnum; i++) {
      if (elf.phType(i) != ElfSegmentType.load) continue;

      final headerStart = elf.phVaddr(i) - image.baseVaddr;
      final headerEnd = headerStart + elf.phFilesz(i);
      final fileStart = elf.phOffset(i);
      final pages = _segmentPages(elf, i, image.baseVaddr);

      // RW while we copy the segment's bytes in, matching upstream's
      // "protect RW, copy, protect final" two-step.
      _protect(
        allocator,
        image,
        pages,
        readable: true,
        writable: true,
        executable: false,
      );

      image.allocation.pointer
          .cast<Uint8>()
          .asTypedList(image.allocation.length)
          .setRange(headerStart, headerEnd, bytes, fileStart);

      // Stay RWX until all RELA are applied. Upstream flips to final perms
      // before reloc; that works on Linux anonymous mmap but on Windows a
      // write into PAGE_EXECUTE_READ during reloc is a hard AV. Final
      // permissions are applied by [_applyFinalProtection].
      _protect(
        allocator,
        image,
        pages,
        readable: true,
        writable: true,
        executable: true,
      );
    }
  }

  /// Single linear pass over section headers, applying relocations
  /// in-place as SHT_RELA sections are encountered — faithfully matching
  /// upstream's ordering-dependent design (relocations are resolved
  /// using whatever dynsym/dynstr/hash-table state has been seen *so
  /// far* in file order, not a two-pass "parse everything, then
  /// relocate" approach). This relies on the conventional toolchain
  /// section ordering (.dynsym/.dynstr before .rela.*), same as
  /// upstream does.
  static _SymbolTables _relocate(
    ElfReader elf,
    Uint8List bytes,
    NativeMemoryAllocator allocator,
    _Image image,
    ExternalSymbolResolver resolveExternalSymbol,
  ) {
    int? symtabOffset;
    int? symtabCount;
    int? strtabOffset;
    GnuHashTable? gnuHash;
    ElfHashTable? elfHash;

    ElfDynamicSymbolTable buildSymtab() => ElfDynamicSymbolTable(
      data: elf.data,
      offset: symtabOffset!,
      count: symtabCount!,
      stringTableOffset: strtabOffset!,
      bytes: bytes,
    );

    for (var i = 0; i < elf.ehShnum; i++) {
      final offset = elf.shOffset(i);
      final size = elf.shSize(i);

      switch (elf.shType(i)) {
        case ElfSectionType.dynamicSymbols:
          symtabOffset = offset;
          symtabCount = size ~/ ElfDynamicSymbolTable.symSize;
        case ElfSectionType.stringTable:
          if (elf.sectionName(i) == '.dynstr') {
            strtabOffset = offset;
          }
        case ElfSectionType.gnuHash:
          gnuHash = GnuHashTable(
            Uint8List.sublistView(bytes, offset, offset + size),
          );
        case ElfSectionType.hash:
          // Matches upstream: only used if no (preferred) GNU hash table
          // has been seen yet.
          elfHash ??= ElfHashTable(
            Uint8List.sublistView(bytes, offset, offset + size),
          );
        case ElfSectionType.rela:
          if (symtabOffset == null || strtabOffset == null) {
            throw StateError(
              'SHT_RELA section encountered before SHT_DYNSYM/.dynstr '
              'were seen; this loader assumes the conventional section '
              "order, matching upstream androidlibrary.d's same "
              'assumption.',
            );
          }
          _applyRelaSection(
            image,
            elf.data,
            offset,
            size,
            buildSymtab(),
            resolveExternalSymbol,
          );
        case ElfSectionType.rel:
          throw StateError(
            'SHT_REL relocation section encountered; only SHT_RELA is '
            'supported here (x86_64 ELF objects always use RELA, never '
            'the legacy implicit-addend REL format).',
          );
        default:
          break;
      }
    }

    final hasSymtab = symtabOffset != null && strtabOffset != null;
    return (
      symtab: hasSymtab ? buildSymtab() : null,
      gnuHash: gnuHash,
      elfHash: elfHash,
    );
  }

  static void _applyRelaSection(
    _Image image,
    ByteData elfData,
    int shOffset,
    int shSize,
    ElfDynamicSymbolTable symtab,
    ExternalSymbolResolver resolveExternalSymbol,
  ) {
    final rela = ElfRelaTable(
      elfData,
      shOffset,
      shSize ~/ ElfRelaTable.relaSize,
    );
    final allocation = image.allocation;
    final base = allocation.pointer.address;

    for (var i = 0; i < rela.count; i++) {
      final type = rela.relocationType(i);
      final symbolIndex = rela.symbolIndex(i);
      final offset = rela.offset(i) - image.baseVaddr;
      final addend = rela.addend(i);

      // Matches upstream: the referenced symbol is always resolved
      // up-front regardless of relocation type, even though RELATIVE
      // relocations (symbolIndex == 0, the null symbol entry) never
      // actually use the result.
      final resolvedAddress = symbolIndex == 0
          ? 0
          : resolveExternalSymbol(symtab.name(symbolIndex)).address;

      final target = (allocation.pointer + offset).cast<Uint64>();

      target.value = switch (type) {
        ElfRelocationType.relative => base + addend,
        ElfRelocationType.globalData => resolvedAddress + addend,
        ElfRelocationType.jumpSlot => resolvedAddress,
        ElfRelocationType.abs64 => resolvedAddress + addend,
        _ => throw StateError('Unknown x86_64 relocation type: $type'),
      };
    }
  }

  /// Relocation needed the whole image RWX (on Windows,
  /// `PAGE_EXECUTE_READ` is not writable); now flip each `PT_LOAD` to the
  /// protection its own `p_flags` asks for.
  static void _applyFinalProtection(
    ElfReader elf,
    NativeMemoryAllocator allocator,
    _Image image,
  ) {
    for (var i = 0; i < elf.ehPhnum; i++) {
      if (elf.phType(i) != ElfSegmentType.load) continue;
      final flags = elf.phFlags(i);
      _protect(
        allocator,
        image,
        _segmentPages(elf, i, image.baseVaddr),
        readable: flags & ElfSegmentFlags.read != 0,
        writable: flags & ElfSegmentFlags.write != 0,
        executable: flags & ElfSegmentFlags.execute != 0,
      );
    }
  }

  /// Resolves an exported symbol to its loaded address. Ported from
  /// `AndroidLibrary.load(string symbolName)` in androidlibrary.d
  /// (upstream reuses `load` for both "resolve one of my own exports"
  /// and, confusingly, the ADI FFI wrapper's per-function lookups; this
  /// is the former — see `native_symbol_stubs.dart`'s dlsym emulation
  /// for the latter).
  @useResult
  Pointer<Void> lookup(String symbolName) {
    final symtab = _symtab;
    if (symtab == null) {
      throw StateError('Library has no dynamic symbol table.');
    }

    final index = switch ((_gnuHash, _elfHash)) {
      (final GnuHashTable gnu, _) => gnu.lookup(symbolName, symtab),
      (_, final ElfHashTable elf) => elf.lookup(symbolName, symtab),
      _ => _linearScan(symbolName, symtab),
    };

    if (index == null) {
      throw StateError('Symbol not found: $symbolName');
    }
    return (base.cast<Uint8>() + symtab.value(index)).cast();
  }

  static int? _linearScan(String symbolName, ElfDynamicSymbolTable symtab) {
    for (var i = 0; i < symtab.count; i++) {
      if (symtab.name(i) == symbolName) return i;
    }
    return null;
  }
}
