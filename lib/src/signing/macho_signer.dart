import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';
import 'package:posix/posix.dart' as posix;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/signing/signing_asset.dart';
import 'package:xcross/src/util/errors.dart';

/// Signs xcross-generated thin arm64 Mach-O files without invoking zsign.
class MachOSigner {
  MachOSigner(this.signingAsset);

  final SigningAsset signingAsset;

  /// Validates the complete Mach-O structure without changing [path].
  static Future<void> preflight(String path) async {
    final bytes = await _read(path);
    _MachO.parse(bytes, path);
  }

  /// Signs [path] through a sibling temporary file and an atomic rename.
  Future<void> signFile(
    String path, {
    required String identifier,
    required String teamIdentifier,
    required Map<String, Object?> entitlements,
    Map<String, Object?>? derEntitlements,
    Uint8List? infoPlistBytes,
    Uint8List? infoPlistSha256,
    Uint8List? codeResourcesBytes,
    Uint8List? codeResourcesSha256,
    DateTime? signingTime,
  }) async {
    final original = await _read(path);
    final signed = signBytes(
      path: path,
      bytes: original,
      identifier: identifier,
      teamIdentifier: teamIdentifier,
      entitlements: entitlements,
      derEntitlements: derEntitlements,
      infoPlistBytes: infoPlistBytes,
      infoPlistSha256: infoPlistSha256,
      codeResourcesBytes: codeResourcesBytes,
      codeResourcesSha256: codeResourcesSha256,
      signingTime: signingTime,
    );
    final int mode;
    try {
      mode = File(path).statSync().mode & 0xfff;
    } on Object catch (error) {
      throw XcrossError('Could not stat Mach-O "$path": $error');
    }
    final temporary = File(
      '$path.xcross-sign-$pid-${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsBytes(signed, flush: true);
      if (!Platform.isWindows && posix.isPosixSupported) {
        posix.chmod(temporary.path, mode.toRadixString(8).padLeft(4, '0'));
      }
      await temporary.rename(path);
    } on Object catch (error) {
      if (temporary.existsSync()) temporary.deleteSync();
      throw XcrossError('Could not atomically replace "$path": $error');
    }
  }

  /// Byte-level signing entry point used by focused synthetic Mach-O tests.
  @visibleForTesting
  Uint8List signBytes({
    required String path,
    required Uint8List bytes,
    required String identifier,
    required String teamIdentifier,
    required Map<String, Object?> entitlements,
    Map<String, Object?>? derEntitlements,
    Uint8List? infoPlistBytes,
    Uint8List? infoPlistSha256,
    Uint8List? codeResourcesBytes,
    Uint8List? codeResourcesSha256,
    DateTime? signingTime,
  }) {
    final macho = _MachO.parse(bytes, path);
    _checkString(identifier, 'identifier', path);
    _checkString(teamIdentifier, 'team identifier', path);
    final infoHash = _hashSource(
      bytes: infoPlistBytes,
      hash: infoPlistSha256,
      field: 'Info.plist hash source',
      path: path,
    );
    final resourcesHash = _hashSource(
      bytes: codeResourcesBytes,
      hash: codeResourcesSha256,
      field: 'CodeResources hash source',
      path: path,
    );
    final isExecutable = macho.fileType == _mhExecute;
    final xmlEntitlements = _entitlementsXml(
      isExecutable ? entitlements : const {},
      path,
    );
    final derEntitlementsBlob = isExecutable
        ? _derEntitlements(derEntitlements ?? entitlements, path)
        : null;
    final requirement = _requirements(
      identifier,
      signingAsset.certificateCommonName,
      path,
    );
    final dataOffset = macho.signatureCommand == null
        ? _align(bytes.length, 16, path, 'signature data offset')
        : macho.signatureDataOffset;
    if (dataOffset > _uint32Max) {
      _fail(path, 'signature data offset', 'exceeds the 32-bit Mach-O field');
    }

    final code = Uint8List(dataOffset);
    code.setRange(
      0,
      bytes.length < dataOffset ? bytes.length : dataOffset,
      bytes,
    );
    final signatureCommandOffset = macho.signatureCommand ?? macho.commandsEnd;
    if (macho.signatureCommand == null) {
      if (macho.commandSlack < 16) {
        _fail(
          path,
          'load-command slack',
          'needs 16 bytes for LC_CODE_SIGNATURE, found '
              '${macho.commandSlack}',
        );
      }
      for (
        var index = signatureCommandOffset;
        index < signatureCommandOffset + 16;
        index++
      ) {
        if (code[index] != 0) {
          _fail(path, 'load-command slack', 'contains non-zero data');
        }
      }
      _setU32le(code, 16, macho.ncmds + 1, path, 'mach_header_64.ncmds');
      _setU32le(
        code,
        20,
        macho.sizeofcmds + 16,
        path,
        'mach_header_64.sizeofcmds',
      );
      _setU32le(code, signatureCommandOffset, _lcCodeSignature, path, 'cmd');
      _setU32le(code, signatureCommandOffset + 4, 16, path, 'cmdsize');
      _setU32le(
        code,
        signatureCommandOffset + 8,
        dataOffset,
        path,
        'LC_CODE_SIGNATURE.dataoff',
      );
    }

    final effectiveSigningTime = signingTime ?? DateTime.now();
    _updateSignatureLayout(
      code,
      macho,
      signatureCommandOffset,
      dataOffset,
      macho.signatureDataSize,
      path,
    );
    final provisional = _buildEmbeddedSignature(
      code: code,
      codeLimit: dataOffset,
      execSegmentLimit: macho.textVmSize,
      identifier: identifier,
      teamIdentifier: teamIdentifier,
      infoHash: infoHash,
      resourcesHash: resourcesHash,
      requirement: requirement,
      xmlEntitlements: xmlEntitlements,
      derEntitlements: derEntitlementsBlob,
      isExecutable: isExecutable,
      signingTime: effectiveSigningTime,
      path: path,
    );
    final needed = _align(
      provisional.length,
      16,
      path,
      'LC_CODE_SIGNATURE.datasize',
    );
    final dataSize =
        macho.signatureCommand != null && macho.signatureDataSize >= needed
        ? macho.signatureDataSize
        : needed;
    final finalLength = _checkedAdd(
      dataOffset,
      dataSize,
      _uint32Max,
      path,
      'final file length',
    );
    _setU32le(
      code,
      signatureCommandOffset + 12,
      dataSize,
      path,
      'LC_CODE_SIGNATURE.datasize',
    );
    _updateLinkedit(code, macho, finalLength, path);

    final signature = _buildEmbeddedSignature(
      code: code,
      codeLimit: dataOffset,
      execSegmentLimit: macho.textVmSize,
      identifier: identifier,
      teamIdentifier: teamIdentifier,
      infoHash: infoHash,
      resourcesHash: resourcesHash,
      requirement: requirement,
      xmlEntitlements: xmlEntitlements,
      derEntitlements: derEntitlementsBlob,
      isExecutable: isExecutable,
      signingTime: effectiveSigningTime,
      path: path,
    );
    if (signature.length > dataSize ||
        _align(signature.length, 16, path, 'signature length') != needed) {
      _fail(path, 'CMS size', 'changed while finalizing the Mach-O layout');
    }
    final output = Uint8List(finalLength)..setRange(0, code.length, code);
    output.setRange(dataOffset, dataOffset + signature.length, signature);
    return output;
  }

  static Future<Uint8List> _read(String path) async {
    try {
      return await File(path).readAsBytes();
    } on Object catch (error) {
      throw XcrossError('Could not read Mach-O "$path": $error');
    }
  }

  static void _updateSignatureLayout(
    Uint8List code,
    _MachO macho,
    int commandOffset,
    int dataOffset,
    int initialDataSize,
    String path,
  ) {
    _setU32le(
      code,
      commandOffset + 8,
      dataOffset,
      path,
      'LC_CODE_SIGNATURE.dataoff',
    );
    _setU32le(
      code,
      commandOffset + 12,
      initialDataSize,
      path,
      'LC_CODE_SIGNATURE.datasize',
    );
    final initialLength = _checkedAdd(
      dataOffset,
      initialDataSize,
      _uint32Max,
      path,
      'provisional file length',
    );
    _updateLinkedit(code, macho, initialLength, path);
  }

  static void _updateLinkedit(
    Uint8List code,
    _MachO macho,
    int finalLength,
    String path,
  ) {
    final fileSize = finalLength - macho.linkeditFileOffset;
    if (fileSize < 0) {
      _fail(path, '__LINKEDIT.filesize', 'would become negative');
    }
    final growth = finalLength - macho.originalLength;
    final vmSize = growth <= 0
        ? macho.linkeditVmSize
        : _align(
            _checkedAdd(
              macho.linkeditVmSize,
              growth,
              _uint32Max,
              path,
              '__LINKEDIT.vmsize',
            ),
            4096,
            path,
            '__LINKEDIT.vmsize',
          );
    if (vmSize < fileSize) {
      _fail(path, '__LINKEDIT.vmsize', 'is smaller than the new filesize');
    }
    _setU64le(
      code,
      macho.linkeditCommand + 32,
      vmSize,
      path,
      '__LINKEDIT.vmsize',
    );
    _setU64le(
      code,
      macho.linkeditCommand + 48,
      fileSize,
      path,
      '__LINKEDIT.filesize',
    );
  }

  Uint8List _buildEmbeddedSignature({
    required Uint8List code,
    required int codeLimit,
    required int execSegmentLimit,
    required String identifier,
    required String teamIdentifier,
    required Uint8List infoHash,
    required Uint8List resourcesHash,
    required Uint8List requirement,
    required Uint8List xmlEntitlements,
    required Uint8List? derEntitlements,
    required bool isExecutable,
    required DateTime signingTime,
    required String path,
  }) {
    final requirementHash = _sha256(requirement);
    final xmlHash = _sha256(xmlEntitlements);
    final derHash = derEntitlements == null ? null : _sha256(derEntitlements);
    final special = <Uint8List>[
      if (isExecutable) derHash!,
      if (isExecutable) Uint8List(32),
      xmlHash,
      Uint8List(32),
      resourcesHash,
      requirementHash,
      infoHash,
    ];
    final execFlags =
        (isExecutable ? _csExecsegMainBinary : 0) |
        (isExecutable && _entitlementsAllowUnsigned(xmlEntitlements)
            ? _csExecsegAllowUnsigned
            : 0);
    final codeDirectory = _codeDirectory(
      code: code,
      codeLimit: codeLimit,
      execSegmentLimit: execSegmentLimit,
      execSegmentFlags: execFlags,
      identifier: identifier,
      teamIdentifier: teamIdentifier,
      specialSlots: special,
      path: path,
    );
    final cdhash = _sha256(codeDirectory);
    final Uint8List cms;
    try {
      cms = signingAsset.buildDetachedCms(
        codeDirectoryBytes: codeDirectory,
        cdhashBytes: cdhash,
        signingTime: signingTime,
      );
    } on Object catch (error) {
      _fail(path, 'CMS signature', '$error');
    }
    final cmsWrapper = _blob(_csMagicBlobWrapper, cms, path, 'CMS wrapper');
    final slots = <({int type, Uint8List bytes})>[
      (type: _csslotCodeDirectory, bytes: codeDirectory),
      (type: _csslotRequirements, bytes: requirement),
      (type: _csslotEntitlements, bytes: xmlEntitlements),
      if (derEntitlements != null)
        (type: _csslotDerEntitlements, bytes: derEntitlements),
      (type: _csslotSignature, bytes: cmsWrapper),
    ];
    final headerLength = _checkedAdd(
      12,
      slots.length * 8,
      _uint32Max,
      path,
      'SuperBlob header length',
    );
    var length = headerLength;
    for (final slot in slots) {
      length = _checkedAdd(
        length,
        slot.bytes.length,
        _uint32Max,
        path,
        'SuperBlob length',
      );
    }
    final output = Uint8List(length);
    _setU32be(output, 0, _csMagicEmbeddedSignature);
    _setU32be(output, 4, length);
    _setU32be(output, 8, slots.length);
    var offset = headerLength;
    for (var index = 0; index < slots.length; index++) {
      _setU32be(output, 12 + index * 8, slots[index].type);
      _setU32be(output, 16 + index * 8, offset);
      output.setRange(
        offset,
        offset + slots[index].bytes.length,
        slots[index].bytes,
      );
      offset += slots[index].bytes.length;
    }
    return output;
  }

  static bool _entitlementsAllowUnsigned(Uint8List xmlEntitlements) {
    final xml = utf8.decode(xmlEntitlements.sublist(8));
    return RegExp(r'<key>get-task-allow</key>\s*<true\s*/>').hasMatch(xml);
  }
}

class _MachO {
  const _MachO({
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

  final int fileType;
  final int ncmds;
  final int sizeofcmds;
  final int commandsEnd;
  final int commandSlack;
  final int textVmSize;
  final int originalLength;
  final int linkeditCommand;
  final int linkeditFileOffset;
  final int linkeditVmSize;
  final int? signatureCommand;
  final int signatureDataOffset;
  final int signatureDataSize;

  factory _MachO.parse(Uint8List bytes, String path) {
    if (bytes.length < 4) _fail(path, 'magic', 'file is truncated');
    final magic = _u32le(bytes, 0);
    if (magic == _fatMagic || magic == _fatCigam) {
      _fail(path, 'magic', 'FAT Mach-O files are unsupported');
    }
    if (magic == _mhMagic || magic == _mhCigam) {
      _fail(path, 'magic', '32-bit Mach-O files are unsupported');
    }
    if (magic == _mhCigam64) {
      _fail(path, 'magic', 'big-endian Mach-O files are unsupported');
    }
    if (magic != _mhMagic64) {
      _fail(path, 'magic', 'not a 64-bit little-endian Mach-O');
    }
    _range(bytes, 0, 32, path, 'mach_header_64');
    if (_u32le(bytes, 4) != _cpuTypeArm64) {
      _fail(path, 'mach_header_64.cputype', 'only ARM64 is supported');
    }
    final fileType = _u32le(bytes, 12);
    final ncmds = _u32le(bytes, 16);
    final sizeofcmds = _u32le(bytes, 20);
    final commandsEnd = _checkedAdd(
      32,
      sizeofcmds,
      bytes.length,
      path,
      'mach_header_64.sizeofcmds',
    );
    if (ncmds > sizeofcmds ~/ 8) {
      _fail(path, 'mach_header_64.ncmds', 'cannot fit in sizeofcmds');
    }

    var command = 32;
    int? textCommand;
    var textVmSize = 0;
    int? textSectionOffset;
    int? firstFileSectionOffset;
    int? linkeditCommand;
    var linkeditFileOffset = 0;
    var linkeditFileSize = 0;
    var linkeditVmSize = 0;
    var greatestNonLinkeditEnd = 0;
    int? signatureCommand;
    var signatureDataOffset = 0;
    var signatureDataSize = 0;
    for (var index = 0; index < ncmds; index++) {
      _range(bytes, command, 8, path, 'load command $index');
      final cmd = _u32le(bytes, command);
      final cmdsize = _u32le(bytes, command + 4);
      if (cmdsize < 8 || !cmdsize.isEven || cmdsize % 8 != 0) {
        _fail(path, 'load command $index.cmdsize', 'must be 8-byte aligned');
      }
      final next = _checkedAdd(
        command,
        cmdsize,
        commandsEnd,
        path,
        'load command $index.cmdsize',
      );
      if (cmd == _lcSegment) {
        _fail(
          path,
          'load command $index.cmd',
          '32-bit segments are unsupported',
        );
      } else if (cmd == _lcSegment64) {
        if (cmdsize < 72) {
          _fail(
            path,
            'load command $index.cmdsize',
            'segment_command_64 is truncated',
          );
        }
        final nsects = _u32le(bytes, command + 64);
        final sectionsSize = _checkedMultiply(
          nsects,
          80,
          _uint32Max,
          path,
          'segment_command_64.nsects',
        );
        if (cmdsize != 72 + sectionsSize) {
          _fail(path, 'segment_command_64.cmdsize', 'does not match nsects');
        }
        final name = _fixedString(bytes, command + 8, 16, path, 'segment name');
        final vmSize = _u64le(bytes, command + 32);
        final fileOffset = _u64le(bytes, command + 40);
        final fileSize = _u64le(bytes, command + 48);
        if (vmSize < fileSize) {
          _fail(path, '$name.vmsize', 'is smaller than filesize');
        }
        final segmentEnd = _checkedAdd(
          fileOffset,
          fileSize,
          bytes.length,
          path,
          '$name file range',
        );
        if (name == '__TEXT') {
          if (textCommand != null) {
            _fail(path, '__TEXT', 'segment is duplicated');
          }
          textCommand = command;
          textVmSize = vmSize;
          if (fileOffset != 0 || commandsEnd > segmentEnd) {
            _fail(
              path,
              '__TEXT file range',
              'does not contain the Mach-O header',
            );
          }
        } else if (name == '__LINKEDIT') {
          if (linkeditCommand != null) {
            _fail(path, '__LINKEDIT', 'segment is duplicated');
          }
          if (fileOffset % 4096 != 0) {
            _fail(path, '__LINKEDIT file offset', 'must be 4096-byte aligned');
          }
          linkeditCommand = command;
          linkeditFileOffset = fileOffset;
          linkeditFileSize = fileSize;
          linkeditVmSize = vmSize;
        }
        if (name != '__LINKEDIT' && segmentEnd > greatestNonLinkeditEnd) {
          greatestNonLinkeditEnd = segmentEnd;
        }
        for (var sectionIndex = 0; sectionIndex < nsects; sectionIndex++) {
          final section = command + 72 + sectionIndex * 80;
          final sectionName = _fixedString(
            bytes,
            section,
            16,
            path,
            '$name section $sectionIndex name',
          );
          final sectionSize = _u64le(bytes, section + 40);
          final sectionOffset = _u32le(bytes, section + 48);
          final sectionType = _u32le(bytes, section + 64) & 0xff;
          final zeroFill =
              sectionType == 1 || sectionType == 0x0c || sectionType == 0x12;
          if (!zeroFill && sectionSize > 0) {
            final sectionEnd = _checkedAdd(
              sectionOffset,
              sectionSize,
              bytes.length,
              path,
              '$name.$sectionName range',
            );
            if (sectionOffset < fileOffset || sectionEnd > segmentEnd) {
              _fail(path, '$name.$sectionName range', 'is outside its segment');
            }
            if (sectionOffset > 0 &&
                (firstFileSectionOffset == null ||
                    sectionOffset < firstFileSectionOffset)) {
              firstFileSectionOffset = sectionOffset;
            }
          }
          if (name == '__TEXT' && sectionName == '__text') {
            if (textSectionOffset != null) {
              _fail(path, '__TEXT.__text', 'section is duplicated');
            }
            textSectionOffset = sectionOffset;
          }
        }
      } else if (cmd == _lcEncryptionInfo || cmd == _lcEncryptionInfo64) {
        final expected = cmd == _lcEncryptionInfo ? 20 : 24;
        if (cmdsize != expected) {
          _fail(path, 'encryption command cmdsize', 'expected $expected');
        }
        if (_u32le(bytes, command + 16) != 0) {
          _fail(
            path,
            'encryption command cryptid',
            'encrypted binaries are unsupported',
          );
        }
      } else if (cmd == _lcCodeSignature) {
        if (signatureCommand != null) {
          _fail(path, 'LC_CODE_SIGNATURE', 'command is duplicated');
        }
        if (cmdsize != 16) {
          _fail(path, 'LC_CODE_SIGNATURE.cmdsize', 'must be 16');
        }
        signatureCommand = command;
        signatureDataOffset = _u32le(bytes, command + 8);
        signatureDataSize = _u32le(bytes, command + 12);
      }
      command = next;
    }
    if (command != commandsEnd) {
      _fail(
        path,
        'mach_header_64.sizeofcmds',
        'does not equal load-command sizes',
      );
    }
    if (textCommand == null || textSectionOffset == null) {
      _fail(path, '__TEXT.__text', 'required section is missing');
    }
    if (linkeditCommand == null) {
      _fail(path, '__LINKEDIT', 'required terminal segment is missing');
    }
    final linkeditEnd = _checkedAdd(
      linkeditFileOffset,
      linkeditFileSize,
      bytes.length,
      path,
      '__LINKEDIT file range',
    );
    if (linkeditEnd != bytes.length ||
        greatestNonLinkeditEnd > linkeditFileOffset) {
      _fail(path, '__LINKEDIT file range', 'segment is not terminal');
    }
    final firstSection = firstFileSectionOffset ?? textSectionOffset;
    if (firstSection < commandsEnd) {
      _fail(path, 'load-command slack', 'overlaps file-backed section data');
    }
    if (signatureCommand == null && firstSection - commandsEnd < 16) {
      _fail(
        path,
        'load-command slack',
        'needs 16 bytes for LC_CODE_SIGNATURE, found '
            '${firstSection - commandsEnd}',
      );
    }
    if (signatureCommand != null) {
      if (signatureDataOffset % 16 != 0 || signatureDataSize % 16 != 0) {
        _fail(
          path,
          'LC_CODE_SIGNATURE alignment',
          'offset and size must be 16-byte aligned',
        );
      }
      if (signatureDataOffset < commandsEnd ||
          signatureDataOffset < linkeditFileOffset) {
        _fail(path, 'LC_CODE_SIGNATURE.dataoff', 'overlaps non-signature data');
      }
      final signatureEnd = _checkedAdd(
        signatureDataOffset,
        signatureDataSize,
        bytes.length,
        path,
        'LC_CODE_SIGNATURE data range',
      );
      if (signatureEnd != bytes.length) {
        _fail(path, 'LC_CODE_SIGNATURE data range', 'must be terminal');
      }
    } else {
      signatureDataOffset = _align(
        bytes.length,
        16,
        path,
        'signature data offset',
      );
    }
    return _MachO(
      fileType: fileType,
      ncmds: ncmds,
      sizeofcmds: sizeofcmds,
      commandsEnd: commandsEnd,
      commandSlack: firstSection - commandsEnd,
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
}

Uint8List _codeDirectory({
  required Uint8List code,
  required int codeLimit,
  required int execSegmentLimit,
  required int execSegmentFlags,
  required String identifier,
  required String teamIdentifier,
  required List<Uint8List> specialSlots,
  required String path,
}) {
  const headerLength = 88;
  const hashSize = 32;
  const pageSize = 4096;
  final identifierBytes = Uint8List.fromList([...utf8.encode(identifier), 0]);
  final teamBytes = Uint8List.fromList([...utf8.encode(teamIdentifier), 0]);
  final codeSlots = (codeLimit + pageSize - 1) ~/ pageSize;
  final hashOffset = _checkedAdd(
    headerLength + identifierBytes.length + teamBytes.length,
    specialSlots.length * hashSize,
    _uint32Max,
    path,
    'CodeDirectory.hashOffset',
  );
  final length = _checkedAdd(
    hashOffset,
    codeSlots * hashSize,
    _uint32Max,
    path,
    'CodeDirectory.length',
  );
  final output = Uint8List(length);
  _setU32be(output, 0, _csMagicCodeDirectory);
  _setU32be(output, 4, length);
  _setU32be(output, 8, 0x20400);
  _setU32be(output, 12, 0);
  _setU32be(output, 16, hashOffset);
  _setU32be(output, 20, headerLength);
  _setU32be(output, 24, specialSlots.length);
  _setU32be(output, 28, codeSlots);
  _setU32be(output, 32, codeLimit);
  output[36] = hashSize;
  output[37] = 2;
  output[39] = 12;
  _setU32be(output, 48, headerLength + identifierBytes.length);
  _setU64be(output, 64, 0);
  _setU64be(output, 72, execSegmentLimit);
  _setU64be(output, 80, execSegmentFlags);
  output.setRange(
    headerLength,
    headerLength + identifierBytes.length,
    identifierBytes,
  );
  output.setRange(
    headerLength + identifierBytes.length,
    headerLength + identifierBytes.length + teamBytes.length,
    teamBytes,
  );
  var offset = headerLength + identifierBytes.length + teamBytes.length;
  for (final hash in specialSlots) {
    if (hash.length != hashSize) {
      _fail(path, 'CodeDirectory special slot', 'SHA-256 hash is not 32 bytes');
    }
    output.setRange(offset, offset + hashSize, hash);
    offset += hashSize;
  }
  for (var slot = 0; slot < codeSlots; slot++) {
    final start = slot * pageSize;
    final end = start + pageSize < codeLimit ? start + pageSize : codeLimit;
    final hash = _sha256(Uint8List.sublistView(code, start, end));
    output.setRange(
      hashOffset + slot * hashSize,
      hashOffset + (slot + 1) * hashSize,
      hash,
    );
  }
  return output;
}

Uint8List _requirements(String identifier, String subject, String path) {
  _checkString(subject, 'certificate common name', path);
  final expression = BytesBuilder(copy: false)
    ..add(_be32(1))
    ..add(_be32(6))
    ..add(_be32(2))
    ..add(_padded(identifier))
    ..add(_be32(6))
    ..add(_be32(15))
    ..add(_be32(6))
    ..add(_be32(11))
    ..add(_be32(0))
    ..add(_padded('subject.CN'))
    ..add(_be32(1))
    ..add(_padded(subject))
    ..add(_be32(14))
    ..add(_be32(1))
    ..add(
      _paddedBytes(const [
        0x2a,
        0x86,
        0x48,
        0x86,
        0xf7,
        0x63,
        0x64,
        0x06,
        0x02,
        0x01,
      ]),
    )
    ..add(_be32(0));
  final expressionBytes = expression.takeBytes();
  final innerLength = 8 + expressionBytes.length;
  final totalLength = 20 + innerLength;
  if (totalLength > _uint32Max) {
    _fail(path, 'designated requirement length', 'exceeds 32 bits');
  }
  return Uint8List.fromList([
    ..._be32(_csMagicRequirements),
    ..._be32(totalLength),
    ..._be32(1),
    ..._be32(3),
    ..._be32(20),
    ..._be32(_csMagicRequirement),
    ..._be32(innerLength),
    ...expressionBytes,
  ]);
}

Uint8List _entitlementsXml(Map<String, Object?> entitlements, String path) {
  final normalized = _normalizePlist(entitlements, path, 'XML entitlements');
  try {
    final xml = PropertyListSerialization.stringWithPropertyList(normalized);
    return _blob(
      _csMagicEmbeddedEntitlements,
      utf8.encode(xml),
      path,
      'XML entitlements',
    );
  } on XcrossError {
    rethrow;
  } on Object catch (error) {
    _fail(path, 'XML entitlements', '$error');
  }
}

Object _normalizePlist(Object? value, String path, String field) {
  if (value is bool || value is int || value is String || value is DateTime) {
    return value!;
  }
  if (value is Uint8List) return ByteData.sublistView(value);
  if (value is ByteData) {
    return ByteData.sublistView(
      Uint8List.fromList(
        value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes),
      ),
    );
  }
  if (value is List<Object?>) {
    return [
      for (var index = 0; index < value.length; index++)
        _normalizePlist(value[index], path, '$field[$index]'),
    ];
  }
  if (value is Map<Object?, Object?>) {
    final result = SplayTreeMap<String, Object?>(_compareStringsUtf8);
    for (final entry in value.entries) {
      if (entry.key is! String) {
        _fail(path, field, 'contains a non-string map key');
      }
      final key = entry.key! as String;
      result[key] = _normalizePlist(entry.value, path, '$field.$key');
    }
    return result;
  }
  _fail(path, field, 'unsupported value type ${value.runtimeType}');
}

Uint8List _derEntitlements(Map<String, Object?> entitlements, String path) {
  final dictionary = _derValue(entitlements, path, 'DER entitlements');
  final body = Uint8List.fromList([0x02, 0x01, 0x01, ...dictionary]);
  final raw = _derTlv(0x70, body);
  return _blob(_csMagicEmbeddedDerEntitlements, raw, path, 'DER entitlements');
}

Uint8List _derValue(Object? value, String path, String field) {
  if (value is bool) {
    return Uint8List.fromList([0x01, 0x01, if (value) 0xff else 0]);
  }
  if (value is int) return _derInteger(value, path, field);
  if (value is String) return _derTlv(0x0c, utf8.encode(value));
  if (value is Uint8List) return _derTlv(0x04, value);
  if (value is ByteData) {
    return _derTlv(
      0x04,
      value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes),
    );
  }
  if (value is DateTime) {
    final utc = value.toUtc();
    if (utc.year < 0 || utc.year > 9999) {
      _fail(path, field, 'date year is outside canonical GeneralizedTime');
    }
    String two(int part) => part.toString().padLeft(2, '0');
    final text =
        '${utc.year.toString().padLeft(4, '0')}'
        '${two(utc.month)}${two(utc.day)}${two(utc.hour)}'
        '${two(utc.minute)}${two(utc.second)}Z';
    return _derTlv(0x18, ascii.encode(text));
  }
  if (value is List<Object?>) {
    return _derTlv(0x30, [
      for (var index = 0; index < value.length; index++)
        ..._derValue(value[index], path, '$field[$index]'),
    ]);
  }
  if (value is Map<Object?, Object?>) {
    final entries = <({Uint8List key, Object? value})>[];
    for (final entry in value.entries) {
      if (entry.key is! String) {
        _fail(path, field, 'contains a non-string map key');
      }
      entries.add((
        key: Uint8List.fromList(utf8.encode(entry.key! as String)),
        value: entry.value,
      ));
    }
    entries.sort((left, right) => _compareBytes(left.key, right.key));
    return _derTlv(0xb0, [
      for (final entry in entries)
        ..._derTlv(0x30, [
          ..._derTlv(0x0c, entry.key),
          ..._derValue(entry.value, path, '$field.${utf8.decode(entry.key)}'),
        ]),
    ]);
  }
  _fail(path, field, 'unsupported value type ${value.runtimeType}');
}

Uint8List _derInteger(int value, String path, String field) {
  const minimum = -0x8000000000000000;
  const maximum = 0x7fffffffffffffff;
  if (value < minimum || value > maximum) {
    _fail(path, field, 'integer is outside the signed 64-bit plist range');
  }
  final bytes = Uint8List(8);
  var current = value;
  for (var index = 7; index >= 0; index--) {
    bytes[index] = current & 0xff;
    current >>= 8;
  }
  var start = 0;
  while (start < 7 &&
      ((bytes[start] == 0 && bytes[start + 1] & 0x80 == 0) ||
          (bytes[start] == 0xff && bytes[start + 1] & 0x80 != 0))) {
    start++;
  }
  return _derTlv(0x02, Uint8List.sublistView(bytes, start));
}

Uint8List _derTlv(int tag, Iterable<int> value) {
  final body = value is Uint8List ? value : Uint8List.fromList(value.toList());
  return Uint8List.fromList([tag, ..._derLength(body.length), ...body]);
}

List<int> _derLength(int value) {
  if (value < 128) return [value];
  final bytes = <int>[];
  var remaining = value;
  while (remaining > 0) {
    bytes.insert(0, remaining & 0xff);
    remaining >>= 8;
  }
  return [0x80 | bytes.length, ...bytes];
}

Uint8List _blob(int magic, Iterable<int> body, String path, String field) {
  final bytes = body is Uint8List ? body : Uint8List.fromList(body.toList());
  final length = _checkedAdd(
    8,
    bytes.length,
    _uint32Max,
    path,
    '$field length',
  );
  return Uint8List.fromList([..._be32(magic), ..._be32(length), ...bytes]);
}

Uint8List _hashSource({
  required Uint8List? bytes,
  required Uint8List? hash,
  required String field,
  required String path,
}) {
  if (bytes != null && hash != null) {
    _fail(path, field, 'provide bytes or a SHA-256 hash, not both');
  }
  if (hash != null) {
    if (hash.length != 32) _fail(path, field, 'SHA-256 hash must be 32 bytes');
    return Uint8List.fromList(hash);
  }
  return bytes == null ? Uint8List(32) : _sha256(bytes);
}

Uint8List _sha256(List<int> bytes) =>
    Uint8List.fromList(crypto.sha256.convert(bytes).bytes);

Uint8List _padded(String value) => _paddedBytes(utf8.encode(value));

Uint8List _paddedBytes(List<int> value) => Uint8List.fromList([
  ..._be32(value.length),
  ...value,
  ...List<int>.filled((4 - value.length % 4) % 4, 0),
]);

Uint8List _be32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);

void _checkString(String value, String field, String path) {
  if (value.isEmpty) _fail(path, field, 'must not be empty');
  if (value.contains('\u0000')) _fail(path, field, 'must not contain NUL');
}

int _checkedAdd(int left, int right, int maximum, String path, String field) {
  if (left < 0 || right < 0 || left > maximum - right) {
    _fail(path, field, 'integer overflow or out-of-bounds range');
  }
  return left + right;
}

int _checkedMultiply(
  int left,
  int right,
  int maximum,
  String path,
  String field,
) {
  if (left < 0 || right < 0 || (left != 0 && right > maximum ~/ left)) {
    _fail(path, field, 'integer overflow');
  }
  return left * right;
}

int _align(int value, int alignment, String path, String field) {
  final remainder = value % alignment;
  return remainder == 0
      ? value
      : _checkedAdd(value, alignment - remainder, _uint32Max, path, field);
}

void _range(
  Uint8List bytes,
  int offset,
  int length,
  String path,
  String field,
) {
  if (offset < 0 || length < 0 || offset > bytes.length - length) {
    _fail(path, field, 'range is outside the file');
  }
}

int _u32le(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset, Endian.little);

int _u64le(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint64(offset, Endian.little);

void _setU32le(
  Uint8List bytes,
  int offset,
  int value,
  String path,
  String field,
) {
  if (value < 0 || value > _uint32Max) _fail(path, field, 'exceeds 32 bits');
  _range(bytes, offset, 4, path, field);
  ByteData.sublistView(bytes).setUint32(offset, value, Endian.little);
}

void _setU64le(
  Uint8List bytes,
  int offset,
  int value,
  String path,
  String field,
) {
  if (value < 0) _fail(path, field, 'must not be negative');
  _range(bytes, offset, 8, path, field);
  ByteData.sublistView(bytes).setUint64(offset, value, Endian.little);
}

void _setU32be(Uint8List bytes, int offset, int value) =>
    ByteData.sublistView(bytes).setUint32(offset, value);

void _setU64be(Uint8List bytes, int offset, int value) =>
    ByteData.sublistView(bytes).setUint64(offset, value);

String _fixedString(
  Uint8List bytes,
  int offset,
  int length,
  String path,
  String field,
) {
  _range(bytes, offset, length, path, field);
  final fieldBytes = Uint8List.sublistView(bytes, offset, offset + length);
  final nul = fieldBytes.indexOf(0);
  try {
    return ascii.decode(nul < 0 ? fieldBytes : fieldBytes.sublist(0, nul));
  } on FormatException {
    _fail(path, field, 'is not ASCII');
  }
}

int _compareStringsUtf8(String left, String right) =>
    _compareBytes(utf8.encode(left), utf8.encode(right));

int _compareBytes(List<int> left, List<int> right) {
  final length = left.length < right.length ? left.length : right.length;
  for (var index = 0; index < length; index++) {
    final comparison = left[index].compareTo(right[index]);
    if (comparison != 0) return comparison;
  }
  return left.length.compareTo(right.length);
}

Never _fail(String path, String field, String reason) =>
    throw XcrossError('Mach-O "$path" has invalid $field: $reason.');

const _uint32Max = 0xffffffff;
const _fatMagic = 0xcafebabe;
const _fatCigam = 0xbebafeca;
const _mhMagic = 0xfeedface;
const _mhCigam = 0xcefaedfe;
const _mhMagic64 = 0xfeedfacf;
const _mhCigam64 = 0xcffaedfe;
const _cpuTypeArm64 = 0x0100000c;
const _mhExecute = 2;
const _lcSegment = 0x1;
const _lcSegment64 = 0x19;
const _lcCodeSignature = 0x1d;
const _lcEncryptionInfo = 0x21;
const _lcEncryptionInfo64 = 0x2c;
const _csMagicRequirement = 0xfade0c00;
const _csMagicRequirements = 0xfade0c01;
const _csMagicCodeDirectory = 0xfade0c02;
const _csMagicEmbeddedSignature = 0xfade0cc0;
const _csMagicBlobWrapper = 0xfade0b01;
const _csMagicEmbeddedEntitlements = 0xfade7171;
const _csMagicEmbeddedDerEntitlements = 0xfade7172;
const _csslotCodeDirectory = 0;
const _csslotRequirements = 2;
const _csslotEntitlements = 5;
const _csslotDerEntitlements = 7;
const _csslotSignature = 0x10000;
const _csExecsegMainBinary = 0x1;
const _csExecsegAllowUnsigned = 0x10;
