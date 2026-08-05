import 'dart:convert';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/errors.dart';

/// Largest value any 32-bit Mach-O field can hold.
const int uint32Max = 0xffffffff;

/// Mach-O page-hash and segment alignment granularity on arm64.
const int machoPageSize = 4096;

/// `LC_CODE_SIGNATURE.dataoff` and `datasize` are both 16-byte aligned.
const int signatureAlignment = 16;

const int fatMagic = 0xcafebabe;
const int fatCigam = 0xbebafeca;
const int mhMagic = 0xfeedface;
const int mhCigam = 0xcefaedfe;
const int mhMagic64 = 0xfeedfacf;
const int mhCigam64 = 0xcffaedfe;

const int cpuTypeArm64 = 0x0100000c;

/// `MH_EXECUTE`: only main executables carry entitlements and exec-seg flags.
const int mhExecute = 2;

const int lcSegment = 0x1;
const int lcSegment64 = 0x19;
const int lcCodeSignature = 0x1d;
const int lcEncryptionInfo = 0x21;
const int lcEncryptionInfo64 = 0x2c;

const String textSegmentName = '__TEXT';
const String linkeditSegmentName = '__LINKEDIT';
const String textSectionName = '__text';

/// `mach_header_64` field offsets from `<mach-o/loader.h>`.
abstract final class MachHeader64 {
  static const int magic = 0;
  static const int cpuType = 4;
  static const int fileType = 12;
  static const int ncmds = 16;
  static const int sizeofcmds = 20;

  /// Header size, and therefore the offset of the first load command.
  static const int size = 32;
}

/// `load_command` field offsets shared by every command.
abstract final class LoadCommand {
  static const int cmd = 0;
  static const int cmdsize = 4;

  /// Bytes that must be readable before `cmdsize` can be trusted.
  static const int size = 8;
}

/// `segment_command_64` field offsets.
abstract final class SegmentCommand64 {
  static const int segname = 8;
  static const int vmsize = 32;
  static const int fileoff = 40;
  static const int filesize = 48;
  static const int nsects = 64;

  /// Command size without sections, and the offset of the first `section_64`.
  static const int size = 72;
}

/// `section_64` field offsets and array stride.
abstract final class Section64 {
  static const int sectname = 0;
  static const int size = 40;
  static const int offset = 48;
  static const int flags = 64;
  static const int stride = 80;
}

/// `LC_CODE_SIGNATURE` field offsets. The command is always 16 bytes.
abstract final class CodeSignatureCommand {
  static const int dataOffset = 8;
  static const int dataSize = 12;
  static const int size = 16;
}

/// Section types whose contents are not file-backed, so their `offset` must
/// not be treated as a file range (`<mach-o/loader.h>` section flags).
const int sZerofill = 0x1;
const int sGbZerofill = 0x0c;
const int sThreadLocalZerofill = 0x12;

/// Length of a fixed 16-byte `char[16]` name field.
const int nameFieldLength = 16;

/// Byte lengths of `encryption_info_command` and its 64-bit variant.
const int encryptionInfoSize = 20;
const int encryptionInfo64Size = 24;

/// Offset of `cryptid` within either encryption command.
const int encryptionCryptIdOffset = 16;

Never machoFail(String path, String field, String reason) =>
    throw AppleError('Mach-O "$path" has invalid $field: $reason.');

void requireRange(
  Uint8List bytes,
  int offset,
  int length,
  String path,
  String field,
) {
  if (offset < 0 || length < 0 || offset > bytes.length - length) {
    machoFail(path, field, 'range is outside the file');
  }
}

int readU32le(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset, Endian.little);

int readU64le(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint64(offset, Endian.little);

void writeU32le(
  Uint8List bytes,
  int offset,
  int value,
  String path,
  String field,
) {
  if (value < 0 || value > uint32Max) machoFail(path, field, 'exceeds 32 bits');
  requireRange(bytes, offset, 4, path, field);
  ByteData.sublistView(bytes).setUint32(offset, value, Endian.little);
}

void writeU64le(
  Uint8List bytes,
  int offset,
  int value,
  String path,
  String field,
) {
  if (value < 0) machoFail(path, field, 'must not be negative');
  requireRange(bytes, offset, 8, path, field);
  ByteData.sublistView(bytes).setUint64(offset, value, Endian.little);
}

/// Reads a NUL-padded ASCII `char[length]` field such as `segname`.
String readFixedString(
  Uint8List bytes,
  int offset,
  int length,
  String path,
  String field,
) {
  requireRange(bytes, offset, length, path, field);
  final fieldBytes = Uint8List.sublistView(bytes, offset, offset + length);
  final nul = fieldBytes.indexOf(0);
  try {
    return ascii.decode(nul < 0 ? fieldBytes : fieldBytes.sublist(0, nul));
  } on FormatException {
    machoFail(path, field, 'is not ASCII');
  }
}

int checkedAdd(int left, int right, int maximum, String path, String field) {
  if (left < 0 || right < 0 || left > maximum - right) {
    machoFail(path, field, 'integer overflow or out-of-bounds range');
  }
  return left + right;
}

int checkedMultiply(
  int left,
  int right,
  int maximum,
  String path,
  String field,
) {
  if (left < 0 || right < 0 || (left != 0 && right > maximum ~/ left)) {
    machoFail(path, field, 'integer overflow');
  }
  return left * right;
}

int alignUp(int value, int alignment, String path, String field) {
  final remainder = value % alignment;
  return remainder == 0
      ? value
      : checkedAdd(value, alignment - remainder, uint32Max, path, field);
}

/// The validated subset of a thin arm64 Mach-O that signing needs.
///
/// Parsing is deliberately strict: anything the signer cannot rewrite safely
/// (fat binaries, 32-bit or big-endian files, encrypted binaries, a
/// non-terminal `__LINKEDIT`) is rejected up front rather than mis-signed.
class MachOLayout {
  const MachOLayout({
    required this.fileType,
    required this.ncmds,
    required this.sizeofcmds,
    required this.commandsEnd,
    required this.commandSlack,
    required this.textVmSize,
    required this.originalLength,
    required this.linkeditCommand,
    required this.linkeditFileOffset,
    required this.linkeditVmSize,
    required this.signatureCommand,
    required this.signatureDataOffset,
    required this.signatureDataSize,
  });

  factory MachOLayout.parse(Uint8List bytes, String path) {
    final header = _Header.read(bytes, path);
    final scan = _CommandScan.walk(bytes, path, header);
    return scan.toLayout(bytes, path, header);
  }

  final int fileType;
  final int ncmds;
  final int sizeofcmds;
  final int commandsEnd;

  /// Zero bytes available between the last load command and the first
  /// file-backed section, where a new `LC_CODE_SIGNATURE` can be injected.
  final int commandSlack;
  final int textVmSize;
  final int originalLength;
  final int linkeditCommand;
  final int linkeditFileOffset;
  final int linkeditVmSize;
  final int? signatureCommand;
  final int signatureDataOffset;
  final int signatureDataSize;
}

/// `mach_header_64` after magic, CPU, and command-table validation.
class _Header {
  const _Header({
    required this.fileType,
    required this.ncmds,
    required this.sizeofcmds,
    required this.commandsEnd,
  });

  factory _Header.read(Uint8List bytes, String path) {
    if (bytes.length < 4) machoFail(path, 'magic', 'file is truncated');
    _requireThinArm64Magic(readU32le(bytes, MachHeader64.magic), path);
    requireRange(bytes, 0, MachHeader64.size, path, 'mach_header_64');
    if (readU32le(bytes, MachHeader64.cpuType) != cpuTypeArm64) {
      machoFail(path, 'mach_header_64.cputype', 'only ARM64 is supported');
    }
    final ncmds = readU32le(bytes, MachHeader64.ncmds);
    final sizeofcmds = readU32le(bytes, MachHeader64.sizeofcmds);
    final commandsEnd = checkedAdd(
      MachHeader64.size,
      sizeofcmds,
      bytes.length,
      path,
      'mach_header_64.sizeofcmds',
    );
    // Every load command is at least LoadCommand.size bytes, so more commands
    // than that many slots cannot possibly fit.
    if (ncmds > sizeofcmds ~/ LoadCommand.size) {
      machoFail(path, 'mach_header_64.ncmds', 'cannot fit in sizeofcmds');
    }
    return _Header(
      fileType: readU32le(bytes, MachHeader64.fileType),
      ncmds: ncmds,
      sizeofcmds: sizeofcmds,
      commandsEnd: commandsEnd,
    );
  }

  static void _requireThinArm64Magic(int magic, String path) {
    if (magic == fatMagic || magic == fatCigam) {
      machoFail(path, 'magic', 'FAT Mach-O files are unsupported');
    }
    if (magic == mhMagic || magic == mhCigam) {
      machoFail(path, 'magic', '32-bit Mach-O files are unsupported');
    }
    if (magic == mhCigam64) {
      machoFail(path, 'magic', 'big-endian Mach-O files are unsupported');
    }
    if (magic != mhMagic64) {
      machoFail(path, 'magic', 'not a 64-bit little-endian Mach-O');
    }
  }

  final int fileType;
  final int ncmds;
  final int sizeofcmds;
  final int commandsEnd;
}

/// Everything the load-command walk accumulates before the terminal checks.
class _CommandScan {
  _CommandScan(this._bytes, this._path, this._header);

  /// Walks all `ncmds` load commands in order, validating as it goes.
  factory _CommandScan.walk(Uint8List bytes, String path, _Header header) {
    final scan = _CommandScan(bytes, path, header);
    var command = MachHeader64.size;
    for (var index = 0; index < header.ncmds; index++) {
      command = scan._readCommand(command, index);
    }
    if (command != header.commandsEnd) {
      machoFail(
        path,
        'mach_header_64.sizeofcmds',
        'does not equal load-command sizes',
      );
    }
    return scan;
  }

  final Uint8List _bytes;
  final String _path;
  final _Header _header;

  int? textCommand;
  int textVmSize = 0;
  int? textSectionOffset;
  int? firstFileSectionOffset;
  int? linkeditCommand;
  int linkeditFileOffset = 0;
  int linkeditFileSize = 0;
  int linkeditVmSize = 0;
  int greatestNonLinkeditEnd = 0;
  int? signatureCommand;
  int signatureDataOffset = 0;
  int signatureDataSize = 0;

  /// Handles the command at [command] and returns the next command offset.
  int _readCommand(int command, int index) {
    requireRange(
      _bytes,
      command,
      LoadCommand.size,
      _path,
      'load command $index',
    );
    final cmd = readU32le(_bytes, command + LoadCommand.cmd);
    final cmdsize = readU32le(_bytes, command + LoadCommand.cmdsize);
    if (cmdsize < LoadCommand.size || !cmdsize.isEven || cmdsize % 8 != 0) {
      machoFail(_path, 'load command $index.cmdsize', 'must be 8-byte aligned');
    }
    final next = checkedAdd(
      command,
      cmdsize,
      _header.commandsEnd,
      _path,
      'load command $index.cmdsize',
    );
    switch (cmd) {
      case lcSegment:
        machoFail(
          _path,
          'load command $index.cmd',
          '32-bit segments are unsupported',
        );
      case lcSegment64:
        _readSegment64(command, cmdsize, index);
      case lcEncryptionInfo || lcEncryptionInfo64:
        _readEncryptionInfo(command, cmdsize, cmd);
      case lcCodeSignature:
        _readCodeSignature(command, cmdsize);
    }
    return next;
  }

  void _readSegment64(int command, int cmdsize, int index) {
    if (cmdsize < SegmentCommand64.size) {
      machoFail(
        _path,
        'load command $index.cmdsize',
        'segment_command_64 is truncated',
      );
    }
    final nsects = readU32le(_bytes, command + SegmentCommand64.nsects);
    final sectionsSize = checkedMultiply(
      nsects,
      Section64.stride,
      uint32Max,
      _path,
      'segment_command_64.nsects',
    );
    if (cmdsize != SegmentCommand64.size + sectionsSize) {
      machoFail(_path, 'segment_command_64.cmdsize', 'does not match nsects');
    }
    final name = readFixedString(
      _bytes,
      command + SegmentCommand64.segname,
      nameFieldLength,
      _path,
      'segment name',
    );
    final vmSize = readU64le(_bytes, command + SegmentCommand64.vmsize);
    final fileOffset = readU64le(_bytes, command + SegmentCommand64.fileoff);
    final fileSize = readU64le(_bytes, command + SegmentCommand64.filesize);
    if (vmSize < fileSize) {
      machoFail(_path, '$name.vmsize', 'is smaller than filesize');
    }
    final segmentEnd = checkedAdd(
      fileOffset,
      fileSize,
      _bytes.length,
      _path,
      '$name file range',
    );
    if (name == textSegmentName) {
      if (textCommand != null) {
        machoFail(_path, textSegmentName, 'segment is duplicated');
      }
      textCommand = command;
      textVmSize = vmSize;
      if (fileOffset != 0 || _header.commandsEnd > segmentEnd) {
        machoFail(
          _path,
          '__TEXT file range',
          'does not contain the Mach-O header',
        );
      }
    } else if (name == linkeditSegmentName) {
      if (linkeditCommand != null) {
        machoFail(_path, linkeditSegmentName, 'segment is duplicated');
      }
      if (fileOffset % machoPageSize != 0) {
        machoFail(_path, '__LINKEDIT file offset', 'must be 4096-byte aligned');
      }
      linkeditCommand = command;
      linkeditFileOffset = fileOffset;
      linkeditFileSize = fileSize;
      linkeditVmSize = vmSize;
    }
    // The signature is appended inside __LINKEDIT, so every other segment has
    // to end before it.
    if (name != linkeditSegmentName && segmentEnd > greatestNonLinkeditEnd) {
      greatestNonLinkeditEnd = segmentEnd;
    }
    _readSections(
      command: command,
      nsects: nsects,
      segmentName: name,
      segmentFileOffset: fileOffset,
      segmentEnd: segmentEnd,
    );
  }

  void _readSections({
    required int command,
    required int nsects,
    required String segmentName,
    required int segmentFileOffset,
    required int segmentEnd,
  }) {
    for (var sectionIndex = 0; sectionIndex < nsects; sectionIndex++) {
      final section =
          command + SegmentCommand64.size + sectionIndex * Section64.stride;
      final sectionName = readFixedString(
        _bytes,
        section + Section64.sectname,
        nameFieldLength,
        _path,
        '$segmentName section $sectionIndex name',
      );
      final sectionSize = readU64le(_bytes, section + Section64.size);
      final sectionOffset = readU32le(_bytes, section + Section64.offset);
      final sectionType = readU32le(_bytes, section + Section64.flags) & 0xff;
      final zeroFill =
          sectionType == sZerofill ||
          sectionType == sGbZerofill ||
          sectionType == sThreadLocalZerofill;
      if (!zeroFill && sectionSize > 0) {
        final sectionEnd = checkedAdd(
          sectionOffset,
          sectionSize,
          _bytes.length,
          _path,
          '$segmentName.$sectionName range',
        );
        if (sectionOffset < segmentFileOffset || sectionEnd > segmentEnd) {
          machoFail(
            _path,
            '$segmentName.$sectionName range',
            'is outside its segment',
          );
        }
        if (sectionOffset > 0 &&
            (firstFileSectionOffset == null ||
                sectionOffset < firstFileSectionOffset!)) {
          firstFileSectionOffset = sectionOffset;
        }
      }
      if (segmentName == textSegmentName && sectionName == textSectionName) {
        if (textSectionOffset != null) {
          machoFail(_path, '__TEXT.__text', 'section is duplicated');
        }
        textSectionOffset = sectionOffset;
      }
    }
  }

  void _readEncryptionInfo(int command, int cmdsize, int cmd) {
    final expected = cmd == lcEncryptionInfo
        ? encryptionInfoSize
        : encryptionInfo64Size;
    if (cmdsize != expected) {
      machoFail(_path, 'encryption command cmdsize', 'expected $expected');
    }
    if (readU32le(_bytes, command + encryptionCryptIdOffset) != 0) {
      machoFail(
        _path,
        'encryption command cryptid',
        'encrypted binaries are unsupported',
      );
    }
  }

  void _readCodeSignature(int command, int cmdsize) {
    if (signatureCommand != null) {
      machoFail(_path, 'LC_CODE_SIGNATURE', 'command is duplicated');
    }
    if (cmdsize != CodeSignatureCommand.size) {
      machoFail(_path, 'LC_CODE_SIGNATURE.cmdsize', 'must be 16');
    }
    signatureCommand = command;
    signatureDataOffset = readU32le(
      _bytes,
      command + CodeSignatureCommand.dataOffset,
    );
    signatureDataSize = readU32le(
      _bytes,
      command + CodeSignatureCommand.dataSize,
    );
  }

  /// Runs the whole-file checks that only make sense once every command has
  /// been seen, then freezes the result.
  MachOLayout toLayout(Uint8List bytes, String path, _Header header) {
    if (textCommand == null || textSectionOffset == null) {
      machoFail(path, '__TEXT.__text', 'required section is missing');
    }
    final linkeditCommand = this.linkeditCommand;
    if (linkeditCommand == null) {
      machoFail(
        path,
        linkeditSegmentName,
        'required terminal segment is missing',
      );
    }
    final linkeditEnd = checkedAdd(
      linkeditFileOffset,
      linkeditFileSize,
      bytes.length,
      path,
      '__LINKEDIT file range',
    );
    // The signature is appended at the very end of the file, which is only
    // safe when __LINKEDIT is the last thing in it.
    if (linkeditEnd != bytes.length ||
        greatestNonLinkeditEnd > linkeditFileOffset) {
      machoFail(path, '__LINKEDIT file range', 'segment is not terminal');
    }
    final firstSection = firstFileSectionOffset ?? textSectionOffset!;
    if (firstSection < header.commandsEnd) {
      machoFail(
        path,
        'load-command slack',
        'overlaps file-backed section data',
      );
    }
    if (signatureCommand == null &&
        firstSection - header.commandsEnd < CodeSignatureCommand.size) {
      machoFail(
        path,
        'load-command slack',
        'needs 16 bytes for LC_CODE_SIGNATURE, found '
            '${firstSection - header.commandsEnd}',
      );
    }
    var signatureDataOffset = this.signatureDataOffset;
    if (signatureCommand != null) {
      _requireUsableSignatureRange(bytes, path, header);
    } else {
      signatureDataOffset = alignUp(
        bytes.length,
        signatureAlignment,
        path,
        'signature data offset',
      );
    }
    return MachOLayout(
      fileType: header.fileType,
      ncmds: header.ncmds,
      sizeofcmds: header.sizeofcmds,
      commandsEnd: header.commandsEnd,
      commandSlack: firstSection - header.commandsEnd,
      textVmSize: textVmSize,
      originalLength: bytes.length,
      linkeditCommand: linkeditCommand,
      linkeditFileOffset: linkeditFileOffset,
      linkeditVmSize: linkeditVmSize,
      signatureCommand: signatureCommand,
      signatureDataOffset: signatureDataOffset,
      signatureDataSize: signatureDataSize,
    );
  }

  void _requireUsableSignatureRange(
    Uint8List bytes,
    String path,
    _Header header,
  ) {
    if (signatureDataOffset % signatureAlignment != 0 ||
        signatureDataSize % signatureAlignment != 0) {
      machoFail(
        path,
        'LC_CODE_SIGNATURE alignment',
        'offset and size must be 16-byte aligned',
      );
    }
    if (signatureDataOffset < header.commandsEnd ||
        signatureDataOffset < linkeditFileOffset) {
      machoFail(
        path,
        'LC_CODE_SIGNATURE.dataoff',
        'overlaps non-signature data',
      );
    }
    final signatureEnd = checkedAdd(
      signatureDataOffset,
      signatureDataSize,
      bytes.length,
      path,
      'LC_CODE_SIGNATURE data range',
    );
    if (signatureEnd != bytes.length) {
      machoFail(path, 'LC_CODE_SIGNATURE data range', 'must be terminal');
    }
  }
}
