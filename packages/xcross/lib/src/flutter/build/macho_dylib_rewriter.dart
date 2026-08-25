import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/errors.dart';

/// Rewrites install names in 64-bit little-endian Mach-O dynamic libraries.
abstract final class MachODylibRewriter {
  static const _magic64 = 0xFEED_FACF;
  static const _cpuTypeArm64 = 0x0100_000c;
  static const _mhDylib = 0x6;
  static const _segment64 = 0x19;
  static const _symtab = 0x2;
  static const _nSect = 0x0e;
  static const _nExt = 0x01;
  static const _fastStubPrefix = r'_objc_msgSend$';

  /// `mach_header_64` is 32 bytes; load commands start right after it.
  static const _headerSize64 = 32;

  /// `LC_ID_DYLIB` — this library's own install name.
  static const _idDylib = 0x0d;

  /// Load commands carrying a dependency's install name. Each has the same
  /// `dylib_command` layout as `LC_ID_DYLIB`.
  static const _dependencyCommands = <int>{
    0x0c, // LC_LOAD_DYLIB
    0x8000_0018, // LC_LOAD_WEAK_DYLIB
    0x8000_001f, // LC_REEXPORT_DYLIB
    0x8000_0023, // LC_LOAD_UPWARD_DYLIB
  };

  /// Byte size of `dylib_command` up to (excluding) its inline name string:
  /// cmd, cmdsize, name offset, timestamp, current version, compat version.
  static const _dylibCommandHeaderSize = 24;

  /// Rewrites [path] in place and leaves unrelated dependency paths unchanged.
  static Future<void> rewriteFile(
    String path, {
    required Set<String> producedDylibNames,
  }) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    final changed = rewriteBytes(
      bytes,
      dylibName: p.basename(path),
      producedDylibNames: producedDylibNames,
      source: path,
    );
    if (changed) await file.writeAsBytes(bytes, flush: true);
  }

  /// Rewrites load-command strings in [bytes]. Returns whether bytes changed.
  @visibleForTesting
  static bool rewriteBytes(
    Uint8List bytes, {
    required String dylibName,
    required Set<String> producedDylibNames,
    String source = 'Mach-O data',
  }) {
    if (bytes.length < _headerSize64) {
      _invalid(source, 'truncated 64-bit header');
    }
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0, Endian.little) != _magic64) {
      _invalid(source, 'expected 64-bit little-endian magic');
    }

    final commandCount = data.getUint32(16, Endian.little);
    final commandsSize = data.getUint32(20, Endian.little);
    final commandsEnd = _headerSize64 + commandsSize;
    if (commandsEnd > bytes.length) {
      _invalid(source, 'load commands exceed file bounds');
    }

    var changed = false;
    final repairFastStubs =
        data.getUint32(4, Endian.little) == _cpuTypeArm64 &&
        data.getUint32(12, Endian.little) == _mhDylib;
    final segmentCommands = <(int, int)>[];
    (int, int)? symtabCommand;
    var commandOffset = _headerSize64;
    for (var index = 0; index < commandCount; index++) {
      if (commandOffset + 8 > commandsEnd) {
        _invalid(source, 'load command $index header exceeds bounds');
      }
      final command = data.getUint32(commandOffset, Endian.little);
      final commandSize = data.getUint32(commandOffset + 4, Endian.little);
      if (commandSize < 8 || commandOffset + commandSize > commandsEnd) {
        _invalid(source, 'load command $index has invalid size $commandSize');
      }

      if (repairFastStubs && command == _segment64) {
        segmentCommands.add((commandOffset, commandSize));
      } else if (repairFastStubs && command == _symtab) {
        if (symtabCommand != null) {
          _invalid(source, 'multiple LC_SYMTAB commands');
        }
        symtabCommand = (commandOffset, commandSize);
      }

      final isId = command == _idDylib;
      if (isId || _dependencyCommands.contains(command)) {
        changed |= _rewriteInstallName(
          bytes,
          data,
          source: source,
          index: index,
          commandOffset: commandOffset,
          commandSize: commandSize,
          isId: isId,
          dylibName: dylibName,
          producedDylibNames: producedDylibNames,
        );
      }
      commandOffset += commandSize;
    }
    if (commandOffset != commandsEnd) {
      _invalid(source, 'load command sizes do not match header');
    }
    if (repairFastStubs) {
      changed |= _repairFastObjCStubs(
        bytes,
        data,
        source: source,
        segmentCommands: segmentCommands,
        symtabCommand: symtabCommand,
      );
    }
    return changed;
  }

  /// Repairs ld64-style fast Objective-C stubs after linking. Some linkers emit
  /// the right selector name and method-name string, but leave the stub's
  /// dedicated selector-reference pointer malformed.
  static bool _repairFastObjCStubs(
    Uint8List bytes,
    ByteData data, {
    required String source,
    required List<(int, int)> segmentCommands,
    required (int, int)? symtabCommand,
  }) {
    if (segmentCommands.isEmpty || symtabCommand == null) return false;

    final sections = <_MachOSection>[];
    for (final (commandOffset, commandSize) in segmentCommands) {
      if (commandSize < 72) {
        _invalid(source, 'LC_SEGMENT_64 is shorter than 72 bytes');
      }
      final sectionCount = data.getUint32(commandOffset + 64, Endian.little);
      if (sectionCount > (commandSize - 72) ~/ 80) {
        _invalid(source, 'LC_SEGMENT_64 sections exceed command bounds');
      }
      final segmentVmAddress = data.getUint64(
        commandOffset + 24,
        Endian.little,
      );
      final segmentVmSize = data.getUint64(commandOffset + 32, Endian.little);
      final segmentFileOffset = data.getUint64(
        commandOffset + 40,
        Endian.little,
      );
      final segmentFileSize = data.getUint64(commandOffset + 48, Endian.little);
      if (!_rangeFits(segmentFileOffset, segmentFileSize, bytes.length)) {
        _invalid(source, 'LC_SEGMENT_64 file range exceeds file bounds');
      }
      for (var index = 0; index < sectionCount; index++) {
        final offset = commandOffset + 72 + index * 80;
        final address = data.getUint64(offset + 32, Endian.little);
        final size = data.getUint64(offset + 40, Endian.little);
        final fileOffset = data.getUint32(offset + 48, Endian.little);
        final sectionType = data.getUint32(offset + 64, Endian.little) & 0xff;
        final hasFileContents =
            sectionType != 1 && sectionType != 0x0c && sectionType != 0x12;
        if (!_rangeFits(address, size, segmentVmAddress + segmentVmSize) ||
            address < segmentVmAddress ||
            (hasFileContents &&
                (!_rangeFits(fileOffset, size, bytes.length) ||
                    fileOffset < segmentFileOffset ||
                    fileOffset + size > segmentFileOffset + segmentFileSize))) {
          _invalid(
            source,
            'section ${sections.length + 1} exceeds its segment',
          );
        }
        sections.add(
          _MachOSection(
            segment: _fixedName(bytes, offset + 16),
            name: _fixedName(bytes, offset),
            address: address,
            size: size,
            fileOffset: fileOffset,
          ),
        );
      }
    }

    final stubs = _onlySection(sections, '__TEXT', '__objc_stubs', source);
    final methodNames = _onlySection(
      sections,
      '__TEXT',
      '__objc_methname',
      source,
    );
    final selectorRefs = _onlySection(
      sections,
      '__DATA',
      '__objc_selrefs',
      source,
      alternateSegment: '__DATA_CONST',
    );
    if (stubs == null || methodNames == null || selectorRefs == null) {
      return false;
    }
    if (selectorRefs.size % 8 != 0) {
      _invalid(source, '__objc_selrefs size is not pointer-aligned');
    }

    final namesByAddress = <int, String>{};
    final addressesByName = <String, List<int>>{};
    var start = methodNames.fileOffset;
    final methodNamesEnd = start + methodNames.size;
    while (start < methodNamesEnd) {
      var end = start;
      while (end < methodNamesEnd && bytes[end] != 0) {
        end++;
      }
      if (end == methodNamesEnd) {
        _invalid(source, '__objc_methname is not null-terminated');
      }
      final name = utf8.decode(bytes.sublist(start, end));
      final address = methodNames.address + start - methodNames.fileOffset;
      namesByAddress[address] = name;
      addressesByName.putIfAbsent(name, () => <int>[]).add(address);
      start = end + 1;
    }

    final validRefsByName = <String, List<int>>{};
    for (var offset = 0; offset < selectorRefs.size; offset += 8) {
      final pointer = data.getUint64(
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

    final (symtabOffset, symtabSize) = symtabCommand;
    if (symtabSize < 24) {
      _invalid(source, 'LC_SYMTAB is shorter than 24 bytes');
    }
    final symbolOffset = data.getUint32(symtabOffset + 8, Endian.little);
    final symbolCount = data.getUint32(symtabOffset + 12, Endian.little);
    final stringsOffset = data.getUint32(symtabOffset + 16, Endian.little);
    final stringsSize = data.getUint32(symtabOffset + 20, Endian.little);
    if (symbolOffset > bytes.length ||
        symbolCount > (bytes.length - symbolOffset) ~/ 16 ||
        !_rangeFits(stringsOffset, stringsSize, bytes.length)) {
      _invalid(source, 'LC_SYMTAB data exceeds file bounds');
    }

    final fastStubs = <_FastObjCStub>[];
    for (var index = 0; index < symbolCount; index++) {
      final offset = symbolOffset + index * 16;
      final type = bytes[offset + 4];
      final sectionIndex = bytes[offset + 5];
      if ((type & 0xe0) != 0 ||
          (type & 0x0e) != _nSect ||
          (type & _nExt) != 0 ||
          sectionIndex == 0 ||
          sectionIndex > sections.length ||
          !identical(sections[sectionIndex - 1], stubs)) {
        continue;
      }
      final stringIndex = data.getUint32(offset, Endian.little);
      if (stringIndex >= stringsSize) {
        _invalid(source, 'symbol $index has an invalid string-table index');
      }
      final nameStart = stringsOffset + stringIndex;
      var nameEnd = nameStart;
      final stringsEnd = stringsOffset + stringsSize;
      while (nameEnd < stringsEnd && bytes[nameEnd] != 0) {
        nameEnd++;
      }
      if (nameEnd == stringsEnd) {
        _invalid(source, 'symbol $index name is not null-terminated');
      }
      final symbolName = utf8.decode(bytes.sublist(nameStart, nameEnd));
      if (!symbolName.startsWith(_fastStubPrefix)) continue;
      final selector = symbolName.substring(_fastStubPrefix.length);
      if (selector.isEmpty || !addressesByName.containsKey(selector)) {
        _invalid(source, 'fast stub selector "$selector" has no method name');
      }
      final address = data.getUint64(offset + 8, Endian.little);
      final relativeOffset = address - stubs.address;
      if (relativeOffset < 0 || relativeOffset + 12 > stubs.size) {
        _invalid(source, 'fast stub "$selector" exceeds __objc_stubs');
      }
      final fileOffset = stubs.fileOffset + relativeOffset;
      final adrp = data.getUint32(fileOffset, Endian.little);
      final ldr = data.getUint32(fileOffset + 4, Endian.little);
      final branch = data.getUint32(fileOffset + 8, Endian.little);
      if ((adrp & 0x9f00001f) != 0x90000001 ||
          (ldr & 0xffc003ff) != 0xf9400021 ||
          (branch & 0xfc000000) != 0x14000000) {
        _invalid(source, 'fast stub "$selector" has unexpected instructions');
      }
      final pageDelta = _signExtend(
        ((adrp >> 5) & 0x7ffff) << 2 | (adrp >> 29) & 3,
        21,
      );
      final refAddress =
          (address & ~0xfff) + pageDelta * 0x1000 + ((ldr >> 10) & 0xfff) * 8;
      if (refAddress < selectorRefs.address ||
          refAddress + 8 > selectorRefs.address + selectorRefs.size ||
          (refAddress - selectorRefs.address) % 8 != 0) {
        _invalid(source, 'fast stub "$selector" does not target a selref');
      }
      fastStubs.add(
        _FastObjCStub(
          selector: selector,
          address: address,
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
    final instructionRepairs = <(_FastObjCStub, int)>[];
    final pointerRepairs = <(int, int)>[];
    for (final stub in fastStubs) {
      final refFileOffset =
          selectorRefs.fileOffset + stub.refAddress - selectorRefs.address;
      final currentPointer = data.getUint64(refFileOffset, Endian.little);
      if (namesByAddress[currentPointer] == stub.selector) continue;

      final matchingRefs = validRefsByName[stub.selector];
      if (matchingRefs != null && matchingRefs.isNotEmpty) {
        instructionRepairs.add((stub, matchingRefs.first));
        continue;
      }
      final intendedAddresses = addressesByName[stub.selector]!;
      if (refUseCounts[stub.refAddress] != 1) {
        _invalid(
          source,
          'fast stub "${stub.selector}" has no safe selref repair',
        );
      }
      pointerRepairs.add((refFileOffset, intendedAddresses.first));
    }

    // Everything above is validation only. Mutate after every repair is known
    // to be representable, so a failure can never leave a partially edited file.
    final encodedInstructions = <(int, int, int)>[];
    for (final (stub, refAddress) in instructionRepairs) {
      final pageDelta = (refAddress & ~0xfff) - (stub.address & ~0xfff);
      if (pageDelta % 0x1000 != 0 ||
          pageDelta < -0x100000000 ||
          pageDelta > 0xfffff000 ||
          (refAddress & 7) != 0) {
        _invalid(source, 'selref for "${stub.selector}" is out of ARM64 range');
      }
      final immediate = (pageDelta ~/ 0x1000) & 0x1fffff;
      final adrp =
          0x90000001 |
          (immediate & 3) << 29 |
          ((immediate >> 2) & 0x7ffff) << 5;
      final ldr = 0xf9400021 | ((refAddress & 0xfff) ~/ 8) << 10;
      encodedInstructions.add((stub.fileOffset, adrp, ldr));
    }
    for (final (offset, pointer) in pointerRepairs) {
      data.setUint64(offset, pointer, Endian.little);
    }
    for (final (offset, adrp, ldr) in encodedInstructions) {
      data
        ..setUint32(offset, adrp, Endian.little)
        ..setUint32(offset + 4, ldr, Endian.little);
    }
    return pointerRepairs.isNotEmpty || instructionRepairs.isNotEmpty;
  }

  static bool _rangeFits(int start, int size, int end) =>
      start >= 0 && size >= 0 && start <= end && size <= end - start;

  static int _signExtend(int value, int bits) {
    final sign = 1 << (bits - 1);
    return (value ^ sign) - sign;
  }

  static String _fixedName(Uint8List bytes, int offset) {
    var end = offset;
    while (end < offset + 16 && bytes[end] != 0) {
      end++;
    }
    return ascii.decode(bytes.sublist(offset, end));
  }

  static _MachOSection? _onlySection(
    List<_MachOSection> sections,
    String segment,
    String name,
    String source, {
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
      _invalid(source, 'multiple $segment,$name sections');
    }
    return matches.firstOrNull;
  }

  /// Rewrites the inline install-name string of one `dylib_command`.
  ///
  /// `LC_ID_DYLIB` always becomes `@rpath/<dylibName>`; a dependency is
  /// rewritten to `@rpath/<basename>` only when we produced that dylib
  /// ourselves, so system and SDK dependencies stay untouched.
  ///
  /// The name lives inside the command's own bytes, so the replacement is
  /// written in place and can never grow: it must stay strictly shorter than
  /// the remaining command bytes to leave room for the NUL terminator. The
  /// slack the linker left as string-table padding is zero-filled first.
  static bool _rewriteInstallName(
    Uint8List bytes,
    ByteData data, {
    required String source,
    required int index,
    required int commandOffset,
    required int commandSize,
    required bool isId,
    required String dylibName,
    required Set<String> producedDylibNames,
  }) {
    if (commandSize < _dylibCommandHeaderSize) {
      _invalid(
        source,
        'dylib command $index is shorter than '
        '$_dylibCommandHeaderSize bytes',
      );
    }
    final nameOffset = data.getUint32(commandOffset + 8, Endian.little);
    if (nameOffset < _dylibCommandHeaderSize || nameOffset >= commandSize) {
      _invalid(
        source,
        'dylib command $index has invalid name offset '
        '$nameOffset',
      );
    }

    final nameStart = commandOffset + nameOffset;
    final commandEnd = commandOffset + commandSize;
    var nameEnd = nameStart;
    while (nameEnd < commandEnd && bytes[nameEnd] != 0) {
      nameEnd++;
    }
    if (nameEnd == commandEnd) {
      _invalid(source, 'dylib command $index name is not null-terminated');
    }

    final oldName = utf8.decode(bytes.sublist(nameStart, nameEnd));
    final basename = oldName.substring(oldName.lastIndexOf('/') + 1);
    final replacement = isId
        ? '@rpath/$dylibName'
        : producedDylibNames.contains(basename)
        ? '@rpath/$basename'
        : null;
    if (replacement == null || replacement == oldName) return false;

    final replacementBytes = utf8.encode(replacement);
    final capacity = commandEnd - nameStart;
    if (replacementBytes.length >= capacity) {
      _invalid(source, 'replacement "$replacement" does not fit "$oldName"');
    }
    bytes.fillRange(nameStart, commandEnd, 0);
    bytes.setRange(
      nameStart,
      nameStart + replacementBytes.length,
      replacementBytes,
    );
    return true;
  }

  static Never _invalid(String source, String message) =>
      throw FlutterBuildError('$source: invalid Mach-O: $message');
}

final class _MachOSection {
  const _MachOSection({
    required this.segment,
    required this.name,
    required this.address,
    required this.size,
    required this.fileOffset,
  });

  final String segment;
  final String name;
  final int address;
  final int size;
  final int fileOffset;
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
