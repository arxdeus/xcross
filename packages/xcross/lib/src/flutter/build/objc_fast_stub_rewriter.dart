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

    final validRefsByName = <String, List<int>>{};
    for (var offset = 0; offset < selectorRefs.size; offset += 8) {
      final pointer = file.data.getUint64(
        selectorRefs.fileOffset + offset,
        Endian.little,
      );
      final name = namesByAddress[pointer];
      if (name != null) {
        validRefsByName
            .putIfAbsent(name, () => <int>[])
            .add(selectorRefs.address + offset);
      }
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

    final refUseCounts = <int, int>{};
    for (final stub in fastStubs) {
      refUseCounts.update(
        stub.refAddress,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }

    // Phase 1: every stub that already has a correct ref, or can adopt an
    // existing valid ref elsewhere, is resolved first. A stub retargeted
    // this way stops reading its old ref, which can free that ref up for
    // whichever other stub still shares it.
    final instructionRepairs = <(_FastObjCStub, int)>[];
    final vacatedCounts = <int, int>{};
    final unresolved = <_FastObjCStub>[];
    for (final stub in fastStubs) {
      final refFileOffset =
          selectorRefs.fileOffset + stub.refAddress - selectorRefs.address;
      final currentPointer = file.data.getUint64(refFileOffset, Endian.little);
      if (namesByAddress[currentPointer] == stub.selector) continue;

      final matchingRefs = validRefsByName[stub.selector];
      if (matchingRefs != null && matchingRefs.isNotEmpty) {
        instructionRepairs.add((stub, matchingRefs.first));
        vacatedCounts.update(
          stub.refAddress,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        continue;
      }
      unresolved.add(stub);
    }

    // Phase 2: everything left still needs its ref rewritten in place.
    // That is only safe once every stub resolved in phase 1 that used to
    // share it has moved away, leaving exactly one remaining reader.
    final pointerRepairs = <(int, int)>[];
    for (final stub in unresolved) {
      final refFileOffset =
          selectorRefs.fileOffset + stub.refAddress - selectorRefs.address;
      final remainingUsers =
          refUseCounts[stub.refAddress]! -
          (vacatedCounts[stub.refAddress] ?? 0);
      if (remainingUsers != 1) {
        fileInvalid(
          file,
          'fast stub "${stub.selector}" has no safe selref repair',
        );
      }
      pointerRepairs.add((
        refFileOffset,
        addressesByName[stub.selector]!.first,
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
