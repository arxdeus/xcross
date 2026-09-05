import 'dart:convert';
import 'dart:typed_data';

import 'package:xcross/src/apple/arm64_instructions.dart';
import 'package:xcross/src/apple/mach_o.dart';

abstract final class ObjCFastStubRewriter {
  static const _nSect = 0x0e;
  static const _nExt = 0x01;
  static const _fastStubPrefix = r'_objc_msgSend$';

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

    final symbolTable = file.parseSymbolTable(symtabs.single);
    final fastStubs = <_FastObjCStub>[];
    for (var index = 0; index < symbolTable.symbolCount; index++) {
      final symbol = symbolTable.symbolAt(index);
      if ((symbol.type & 0xe0) != 0 ||
          (symbol.type & 0x0e) != _nSect ||
          (symbol.type & _nExt) != 0 ||
          symbol.sectionIndex == 0 ||
          symbol.sectionIndex > sections.length ||
          !identical(sections[symbol.sectionIndex - 1], stubs)) {
        continue;
      }
      final symbolName = symbolTable.symbolName(index, symbol);
      if (!symbolName.startsWith(_fastStubPrefix)) continue;
      final selector = symbolName.substring(_fastStubPrefix.length);
      if (selector.isEmpty || !addressesByName.containsKey(selector)) {
        fileInvalid(file, 'fast stub selector "$selector" has no method name');
      }
      final relativeOffset = symbol.value - stubs.address;
      if (relativeOffset < 0 || relativeOffset + 12 > stubs.size) {
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
      if (refAddress == null || (branch & 0xfc000000) != 0x14000000) {
        fileInvalid(file, 'fast stub "$selector" has unexpected instructions');
      }
      if (refAddress < selectorRefs.address ||
          refAddress + 8 > selectorRefs.address + selectorRefs.size ||
          (refAddress - selectorRefs.address) % 8 != 0) {
        fileInvalid(file, 'fast stub "$selector" does not target a selref');
      }
      fastStubs.add(
        _FastObjCStub(
          selector: selector,
          address: symbol.value,
          fileOffset: fileOffset,
          refAddress: refAddress,
        ),
      );
    }

    final readersByRef = <int, List<_FastObjCStub>>{};
    for (final stub in fastStubs) {
      readersByRef
          .putIfAbsent(stub.refAddress, () => <_FastObjCStub>[])
          .add(stub);
    }
    String? pointee(int refAddress) =>
        namesByAddress[file.data.getUint64(
          selectorRefs.fileOffset + refAddress - selectorRefs.address,
          Endian.little,
        )];

    // ld64.lld synthesises one selref per stub, so a stub is normally the
    // sole reader of its ref and the ref is repaired in place. Refs shared
    // by several stubs only arise from files an earlier repair touched. A
    // stub may move to another ref only when that ref's final contents are
    // settled: nobody reads it (it stays as is) or exactly one stub does
    // (it ends up naming that stub's selector). Refs with several readers
    // are never adopted, since they may still be rewritten below.
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

    final pointerRepairs = <(int, int)>[];
    final instructionRepairs = <(_FastObjCStub, int)>[];
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

      final staying = <_FastObjCStub>[];
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
      file.data.setUint64(offset, pointer, Endian.little);
    }
    for (final (offset, instructions) in encodedInstructions) {
      file.data
        ..setUint32(offset, instructions.adrp, Endian.little)
        ..setUint32(offset + 4, instructions.ldr, Endian.little);
    }
    return pointerRepairs.isNotEmpty || instructionRepairs.isNotEmpty;
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

final class _FastObjCStub {
  const _FastObjCStub({
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
