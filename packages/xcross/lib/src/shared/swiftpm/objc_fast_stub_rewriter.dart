import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:xcross/src/shared/apple/arm64_instructions.dart';
import 'package:xcross/src/shared/apple/mach_o.dart';

@internal
abstract final class ObjCFastStubRewriter {
  static const _nSect = 0x0e;
  static const _nExt = 0x01;
  static const _fastStubPrefix = r'_objc_msgSend$';

  /// A `__DATA`/`__DATA_CONST` slot in a chained-fixups image is not a plain
  /// pointer: `DYLD_CHAINED_PTR_64` keeps the target in the low 36 bits and
  /// packs dyld's own state above it — most importantly the 12-bit `next`
  /// delta at bit 51, which links every slot on a page into one chain.
  ///
  /// Rewriting a selref by storing a bare address therefore zeroes that
  /// delta and terminates the page's chain early, so dyld stops rebasing at
  /// that slot and every later pointer on the page keeps its unslid
  /// file-relative value. The first ObjC class whose `name` landed past the
  /// break then makes `objc::ObjectHashTable::forEachObject` dereference an
  /// unrebased address, and the process dies in `dyld4::PrebuiltObjC` before
  /// `main` (arxdeus/xcross: AppAuth's `OID*` classes on a Firebase app).
  static const _chainedTargetMask = 0xFFFFFFFFF; // bits 0-35

  /// Target address held by a chained-fixup slot.
  static int _chainedTarget(int raw) => raw & _chainedTargetMask;

  /// [raw] with its target replaced by [target], keeping dyld's metadata.
  static int _withChainedTarget(int raw, int target) =>
      (raw & ~_chainedTargetMask) | (target & _chainedTargetMask);

  static bool repair(MachOFile file) {
    final segments = file.commands
        .where((command) => command.type == MachOConstants.lcSegment64)
        .toList();
    final symtabs = file.commands
        .where((command) => command.type == MachOConstants.lcSymtab)
        .toList();
    if (symtabs.length > 1) fileInvalid(file, 'multiple LC_SYMTAB commands');
    if (segments.isEmpty || symtabs.isEmpty) return false;

    final sections = file.parseSections(segments);
    final stubs = _onlySection(file, sections, '__TEXT', '__objc_stubs');
    final methodNames = _onlySection(
      file,
      sections,
      '__TEXT',
      '__objc_methname',
    );
    final selectorRefs = _onlySection(
      file,
      sections,
      '__DATA',
      '__objc_selrefs',
      alternateSegment: '__DATA_CONST',
    );
    if (stubs == null || methodNames == null || selectorRefs == null) {
      return false;
    }
    if (selectorRefs.size % 8 != 0) {
      fileInvalid(file, '__objc_selrefs size is not pointer-aligned');
    }

    final (:namesByAddress, :addressesByName) = _parseMethodNames(
      file,
      methodNames,
    );
    final fastStubs = _parseFastStubs(
      file,
      symbolTable: file.parseSymbolTable(symtabs.single),
      sections: sections,
      stubs: stubs,
      selectorRefs: selectorRefs,
      addressesByName: addressesByName,
    );

    final readersByRef = <int, List<FastObjCStub>>{};
    for (final stub in fastStubs) {
      readersByRef
          .putIfAbsent(stub.refAddress, () => <FastObjCStub>[])
          .add(stub);
    }
    String? pointee(int refAddress) =>
        namesByAddress[_chainedTarget(
          file.data.getUint64(
            selectorRefs.fileOffset + refAddress - selectorRefs.address,
            Endian.little,
          ),
        )];

    final settledRefsByName = _settledRefsByName(
      selectorRefs,
      readersByRef,
      pointee,
    );
    final (:pointerRepairs, :instructionRepairs) = _planRepairs(
      file,
      selectorRefs: selectorRefs,
      readersByRef: readersByRef,
      settledRefsByName: settledRefsByName,
      addressesByName: addressesByName,
      pointee: pointee,
    );
    _applyRepairs(file, pointerRepairs, instructionRepairs);
    return pointerRepairs.isNotEmpty || instructionRepairs.isNotEmpty;
  }

  static ({
    Map<int, String> namesByAddress,
    Map<String, List<int>> addressesByName,
  })
  _parseMethodNames(MachOFile file, MachOSection methodNames) {
    final namesByAddress = <int, String>{};
    final addressesByName = <String, List<int>>{};
    var start = methodNames.fileOffset;
    final methodNamesEnd = start + methodNames.size;
    while (start < methodNamesEnd) {
      var end = start;
      while (end < methodNamesEnd && file.bytes[end] != 0) {
        end++;
      }
      if (end == methodNamesEnd) {
        fileInvalid(file, '__objc_methname is not null-terminated');
      }
      final name = utf8.decode(file.bytes.sublist(start, end));
      final address = methodNames.address + start - methodNames.fileOffset;
      namesByAddress[address] = name;
      addressesByName.putIfAbsent(name, () => <int>[]).add(address);
      start = end + 1;
    }
    return (namesByAddress: namesByAddress, addressesByName: addressesByName);
  }

  static List<FastObjCStub> _parseFastStubs(
    MachOFile file, {
    required MachOSymbolTable symbolTable,
    required List<MachOSection> sections,
    required MachOSection stubs,
    required MachOSection selectorRefs,
    required Map<String, List<int>> addressesByName,
  }) {
    final fastStubs = <FastObjCStub>[];
    for (var index = 0; index < symbolTable.symbolCount; index++) {
      final symbol = symbolTable.symbolAt(index);
      if (!_isLocalSymbolInSection(symbol, sections, stubs)) continue;
      final symbolName = symbolTable.symbolName(index, symbol);
      if (!symbolName.startsWith(_fastStubPrefix)) continue;
      final selector = symbolName.substring(_fastStubPrefix.length);
      final hasMethodName =
          selector.isNotEmpty && addressesByName.containsKey(selector);
      if (!hasMethodName) {
        fileInvalid(file, 'fast stub selector "$selector" has no method name');
      }
      fastStubs.add(
        _readFastStub(
          file,
          symbol: symbol,
          selector: selector,
          stubs: stubs,
          selectorRefs: selectorRefs,
        ),
      );
    }
    return fastStubs;
  }

  static bool _isLocalSymbolInSection(
    MachOSymbol symbol,
    List<MachOSection> sections,
    MachOSection section,
  ) {
    final isPlainSectionSymbol =
        (symbol.type & 0xe0) == 0 && (symbol.type & 0x0e) == _nSect;
    final isLocal = (symbol.type & _nExt) == 0;
    final hasSectionIndex =
        symbol.sectionIndex != 0 && symbol.sectionIndex <= sections.length;
    return isPlainSectionSymbol &&
        isLocal &&
        hasSectionIndex &&
        identical(sections[symbol.sectionIndex - 1], section);
  }

  static FastObjCStub _readFastStub(
    MachOFile file, {
    required MachOSymbol symbol,
    required String selector,
    required MachOSection stubs,
    required MachOSection selectorRefs,
  }) {
    final relativeOffset = symbol.value - stubs.address;
    final fitsInStubs =
        relativeOffset >= 0 && relativeOffset + 12 <= stubs.size;
    if (!fitsInStubs) {
      fileInvalid(file, 'fast stub "$selector" exceeds __objc_stubs');
    }
    final fileOffset = stubs.fileOffset + relativeOffset;
    final adrp = file.data.getUint32(fileOffset, Endian.little);
    final ldr = file.data.getUint32(fileOffset + 4, Endian.little);
    final branch = file.data.getUint32(fileOffset + 8, Endian.little);
    final refAddress = Arm64AdrpLdr.decodeTarget(
      adrp: adrp,
      ldr: ldr,
      instructionAddress: symbol.value,
    );
    final isBranch = (branch & 0xfc000000) == 0x14000000;
    if (refAddress == null || !isBranch) {
      fileInvalid(file, 'fast stub "$selector" has unexpected instructions');
    }
    final selectorRefsEnd = selectorRefs.address + selectorRefs.size;
    final targetsSelref =
        refAddress >= selectorRefs.address &&
        refAddress + 8 <= selectorRefsEnd &&
        (refAddress - selectorRefs.address) % 8 == 0;
    if (!targetsSelref) {
      fileInvalid(file, 'fast stub "$selector" does not target a selref');
    }
    return FastObjCStub(
      selector: selector,
      address: symbol.value,
      fileOffset: fileOffset,
      refAddress: refAddress,
    );
  }

  // ld64.lld synthesises one selref per stub, so a stub is normally the
  // sole reader of its ref and the ref is repaired in place. Refs shared
  // by several stubs only arise from files an earlier repair touched. A
  // stub may move to another ref only when that ref's final contents are
  // settled: nobody reads it (it stays as is) or exactly one stub does
  // (it ends up naming that stub's selector). Refs with several readers
  // are never adopted, since they may still be rewritten below.
  static Map<String, List<int>> _settledRefsByName(
    MachOSection selectorRefs,
    Map<int, List<FastObjCStub>> readersByRef,
    String? Function(int refAddress) pointee,
  ) {
    final settledRefsByName = <String, List<int>>{};
    for (var offset = 0; offset < selectorRefs.size; offset += 8) {
      final refAddress = selectorRefs.address + offset;
      final readers = readersByRef[refAddress];
      final String? name;
      if (readers == null) {
        name = pointee(refAddress);
      } else if (readers.length == 1) {
        name = readers.single.selector;
      } else {
        continue;
      }
      if (name != null) {
        settledRefsByName.putIfAbsent(name, () => <int>[]).add(refAddress);
      }
    }
    return settledRefsByName;
  }

  static ({
    List<(int, int)> pointerRepairs,
    List<(FastObjCStub, int)> instructionRepairs,
  })
  _planRepairs(
    MachOFile file, {
    required MachOSection selectorRefs,
    required Map<int, List<FastObjCStub>> readersByRef,
    required Map<String, List<int>> settledRefsByName,
    required Map<String, List<int>> addressesByName,
    required String? Function(int refAddress) pointee,
  }) {
    final pointerRepairs = <(int, int)>[];
    final instructionRepairs = <(FastObjCStub, int)>[];
    for (final MapEntry(key: refAddress, value: readers)
        in readersByRef.entries) {
      final current = pointee(refAddress);
      final refFileOffset =
          selectorRefs.fileOffset + refAddress - selectorRefs.address;
      if (readers.length == 1) {
        final stub = readers.single;
        if (current != stub.selector) {
          pointerRepairs.add((
            refFileOffset,
            addressesByName[stub.selector]!.first,
          ));
        }
        continue;
      }

      final staying = <FastObjCStub>[];
      for (final stub in readers) {
        if (current == stub.selector) {
          staying.add(stub);
          continue;
        }
        final settled = settledRefsByName[stub.selector];
        if (settled != null && settled.isNotEmpty) {
          instructionRepairs.add((stub, settled.first));
          continue;
        }
        staying.add(stub);
      }
      final mismatched = staying.where((stub) => stub.selector != current);
      if (mismatched.isEmpty) continue;
      if (staying.length != 1) {
        fileInvalid(
          file,
          'fast stub "${mismatched.first.selector}" has no safe selref '
          'repair (a clean build with ld64.lld 19 or newer avoids this)',
        );
      }
      pointerRepairs.add((
        refFileOffset,
        addressesByName[staying.single.selector]!.first,
      ));
    }
    return (
      pointerRepairs: pointerRepairs,
      instructionRepairs: instructionRepairs,
    );
  }

  static void _applyRepairs(
    MachOFile file,
    List<(int, int)> pointerRepairs,
    List<(FastObjCStub, int)> instructionRepairs,
  ) {
    // Validate and encode every repair before mutating the file.
    final encodedInstructions = <(int, Arm64AdrpLdr)>[];
    for (final (stub, refAddress) in instructionRepairs) {
      final instructions = Arm64AdrpLdr.encodeTarget(
        targetAddress: refAddress,
        instructionAddress: stub.address,
      );
      if (instructions == null) {
        fileInvalid(
          file,
          'selref for "${stub.selector}" is out of ARM64 range',
        );
      }
      encodedInstructions.add((stub.fileOffset, instructions));
    }
    for (final (offset, pointer) in pointerRepairs) {
      // Keep the slot's chained-fixup metadata: only the target changes.
      final raw = file.data.getUint64(offset, Endian.little);
      file.data.setUint64(
        offset,
        _withChainedTarget(raw, pointer),
        Endian.little,
      );
    }
    for (final (offset, instructions) in encodedInstructions) {
      file.data
        ..setUint32(offset, instructions.adrp, Endian.little)
        ..setUint32(offset + 4, instructions.ldr, Endian.little);
    }
  }

  static MachOSection? _onlySection(
    MachOFile file,
    List<MachOSection> sections,
    String segment,
    String name, {
    String? alternateSegment,
  }) {
    final matches = sections
        .where(
          (section) =>
              section.name == name &&
              (section.segment == segment ||
                  section.segment == alternateSegment),
        )
        .toList();
    if (matches.length > 1) {
      fileInvalid(file, 'multiple $segment,$name sections');
    }
    return matches.firstOrNull;
  }

  static Never fileInvalid(MachOFile file, String message) =>
      file.invalid(message);
}

@internal
final class FastObjCStub {
  const FastObjCStub({
    required this.selector,
    required this.address,
    required this.fileOffset,
    required this.refAddress,
  });

  final String selector;
  final int address;
  final int fileOffset;
  final int refAddress;
}
