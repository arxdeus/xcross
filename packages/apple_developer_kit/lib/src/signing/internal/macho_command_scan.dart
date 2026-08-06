import 'dart:typed_data';

import 'package:apple_developer_kit/src/signing/internal/macho_header.dart';
import 'package:apple_developer_kit/src/signing/macho_format.dart';

/// Everything the load-command walk accumulates before the terminal checks.
final class MachOCommandScan {
  MachOCommandScan(this._bytes, this._path, this._header);

  /// Walks all `ncmds` load commands in order, validating as it goes.
  factory MachOCommandScan.walk(
    Uint8List bytes,
    String path,
    MachOHeader header,
  ) {
    final scan = MachOCommandScan(bytes, path, header);
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
  final MachOHeader _header;

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
      final sectionType = readU32le(_bytes, section + Section64.flags) & 0xFF;
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
  MachOLayout toLayout(Uint8List bytes, String path, MachOHeader header) {
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
    MachOHeader header,
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
