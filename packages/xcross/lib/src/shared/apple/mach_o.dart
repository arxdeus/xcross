import 'dart:convert';
import 'dart:typed_data';

typedef InvalidMachO = Never Function(String message);

abstract final class MachOConstants {
  static const magic64 = 0xFEED_FACF;
  static const cpuTypeArm64 = 0x0100_000c;
  static const mhDylib = 0x6;
  static const lcSegment64 = 0x19;
  static const lcSymtab = 0x2;
  static const headerSize64 = 32;
}

final class MachOFile {
  MachOFile._({
    required this.bytes,
    required this.data,
    required this.cpuType,
    required this.fileType,
    required this.commands,
    required InvalidMachO invalid,
  }) : _invalid = invalid;

  factory MachOFile.parse(Uint8List bytes, {required InvalidMachO invalid}) {
    if (bytes.length < MachOConstants.headerSize64) {
      invalid('truncated 64-bit header');
    }
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0, Endian.little) != MachOConstants.magic64) {
      invalid('expected 64-bit little-endian magic');
    }
    final commandCount = data.getUint32(16, Endian.little);
    final commandsSize = data.getUint32(20, Endian.little);
    final commandsEnd = MachOConstants.headerSize64 + commandsSize;
    if (commandsEnd > bytes.length) {
      invalid('load commands exceed file bounds');
    }

    final commands = <MachOLoadCommand>[];
    var offset = MachOConstants.headerSize64;
    for (var index = 0; index < commandCount; index++) {
      if (offset + 8 > commandsEnd) {
        invalid('load command $index header exceeds bounds');
      }
      final type = data.getUint32(offset, Endian.little);
      final size = data.getUint32(offset + 4, Endian.little);
      if (size < 8 || offset + size > commandsEnd) {
        invalid('load command $index has invalid size $size');
      }
      commands.add(
        MachOLoadCommand(index: index, type: type, offset: offset, size: size),
      );
      offset += size;
    }
    if (offset != commandsEnd) {
      invalid('load command sizes do not match header');
    }
    return MachOFile._(
      bytes: bytes,
      data: data,
      cpuType: data.getUint32(4, Endian.little),
      fileType: data.getUint32(12, Endian.little),
      commands: commands,
      invalid: invalid,
    );
  }

  final Uint8List bytes;
  final ByteData data;
  final int cpuType;
  final int fileType;
  final List<MachOLoadCommand> commands;
  final InvalidMachO _invalid;

  Never invalid(String message) => _invalid(message);

  List<MachOSection> parseSections(Iterable<MachOLoadCommand> segments) {
    final sections = <MachOSection>[];
    for (final command in segments) {
      if (command.size < 72) {
        _invalid('LC_SEGMENT_64 is shorter than 72 bytes');
      }
      final count = data.getUint32(command.offset + 64, Endian.little);
      if (count > (command.size - 72) ~/ 80) {
        _invalid('LC_SEGMENT_64 sections exceed command bounds');
      }
      final vmAddress = data.getUint64(command.offset + 24, Endian.little);
      final vmSize = data.getUint64(command.offset + 32, Endian.little);
      final fileOffset = data.getUint64(command.offset + 40, Endian.little);
      final fileSize = data.getUint64(command.offset + 48, Endian.little);
      if (!rangeFits(fileOffset, fileSize, bytes.length)) {
        _invalid('LC_SEGMENT_64 file range exceeds file bounds');
      }
      for (var index = 0; index < count; index++) {
        final offset = command.offset + 72 + index * 80;
        final address = data.getUint64(offset + 32, Endian.little);
        final size = data.getUint64(offset + 40, Endian.little);
        final sectionFileOffset = data.getUint32(offset + 48, Endian.little);
        final sectionType = data.getUint32(offset + 64, Endian.little) & 0xff;
        final hasFileContents =
            sectionType != 1 && sectionType != 0x0c && sectionType != 0x12;
        if (!rangeFits(address, size, vmAddress + vmSize) ||
            address < vmAddress ||
            (hasFileContents &&
                (!rangeFits(sectionFileOffset, size, bytes.length) ||
                    sectionFileOffset < fileOffset ||
                    sectionFileOffset + size > fileOffset + fileSize))) {
          _invalid('section ${sections.length + 1} exceeds its segment');
        }
        sections.add(
          MachOSection(
            segment: fixedName(offset + 16),
            name: fixedName(offset),
            address: address,
            size: size,
            fileOffset: sectionFileOffset,
          ),
        );
      }
    }
    return sections;
  }

  MachOSymbolTable parseSymbolTable(MachOLoadCommand command) {
    if (command.size < 24) {
      _invalid('LC_SYMTAB is shorter than 24 bytes');
    }
    final symbolOffset = data.getUint32(command.offset + 8, Endian.little);
    final symbolCount = data.getUint32(command.offset + 12, Endian.little);
    final stringsOffset = data.getUint32(command.offset + 16, Endian.little);
    final stringsSize = data.getUint32(command.offset + 20, Endian.little);
    if (symbolOffset > bytes.length ||
        symbolCount > (bytes.length - symbolOffset) ~/ 16 ||
        !rangeFits(stringsOffset, stringsSize, bytes.length)) {
      _invalid('LC_SYMTAB data exceeds file bounds');
    }
    return MachOSymbolTable(
      file: this,
      symbolOffset: symbolOffset,
      symbolCount: symbolCount,
      stringsOffset: stringsOffset,
      stringsSize: stringsSize,
    );
  }

  String fixedName(int offset) {
    var end = offset;
    while (end < offset + 16 && bytes[end] != 0) {
      end++;
    }
    return ascii.decode(bytes.sublist(offset, end));
  }

  String nullTerminatedString(int start, int end, String error) {
    var stringEnd = start;
    while (stringEnd < end && bytes[stringEnd] != 0) {
      stringEnd++;
    }
    if (stringEnd == end) _invalid(error);
    return utf8.decode(bytes.sublist(start, stringEnd));
  }

  static bool rangeFits(int start, int size, int end) =>
      start >= 0 && size >= 0 && start <= end && size <= end - start;
}

final class MachOLoadCommand {
  const MachOLoadCommand({
    required this.index,
    required this.type,
    required this.offset,
    required this.size,
  });

  final int index;
  final int type;
  final int offset;
  final int size;
}

final class MachOSection {
  const MachOSection({
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

final class MachOSymbolTable {
  const MachOSymbolTable({
    required this.file,
    required this.symbolOffset,
    required this.symbolCount,
    required this.stringsOffset,
    required this.stringsSize,
  });

  final MachOFile file;
  final int symbolOffset;
  final int symbolCount;
  final int stringsOffset;
  final int stringsSize;

  MachOSymbol symbolAt(int index) {
    final offset = symbolOffset + index * 16;
    return MachOSymbol(
      stringIndex: file.data.getUint32(offset, Endian.little),
      type: file.bytes[offset + 4],
      sectionIndex: file.bytes[offset + 5],
      value: file.data.getUint64(offset + 8, Endian.little),
    );
  }

  String symbolName(int index, MachOSymbol symbol) {
    if (symbol.stringIndex >= stringsSize) {
      file._invalid('symbol $index has an invalid string-table index');
    }
    return file.nullTerminatedString(
      stringsOffset + symbol.stringIndex,
      stringsOffset + stringsSize,
      'symbol $index name is not null-terminated',
    );
  }
}

final class MachOSymbol {
  const MachOSymbol({
    required this.stringIndex,
    required this.type,
    required this.sectionIndex,
    required this.value,
  });

  final int stringIndex;
  final int type;
  final int sectionIndex;
  final int value;
}
