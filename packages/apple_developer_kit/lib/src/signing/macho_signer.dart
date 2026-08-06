import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/signing/code_signature.dart';
import 'package:apple_developer_kit/src/signing/internal/signature_inputs.dart';
import 'package:apple_developer_kit/src/signing/macho_format.dart';
import 'package:apple_developer_kit/src/signing/signing_asset.dart';
import 'package:meta/meta.dart';
import 'package:posix/posix.dart' as posix;

/// Signs xcross-generated thin arm64 Mach-O files without invoking zsign.
class MachOSigner {
  MachOSigner(this.signingAsset);

  final SigningAsset signingAsset;

  /// Validates the complete Mach-O structure without changing [path].
  static Future<void> preflight(String path) async {
    final bytes = await _read(path);
    MachOLayout.parse(bytes, path);
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
      throw AppleError('Could not stat Mach-O "$path": $error');
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
      throw AppleError('Could not atomically replace "$path": $error');
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
    final macho = MachOLayout.parse(bytes, path);
    final inputs = _collectInputs(
      macho: macho,
      path: path,
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

    final dataOffset = _signatureDataOffset(macho, bytes, path);
    final commandOffset = macho.signatureCommand ?? macho.commandsEnd;
    final code = _buildCodeImage(
      bytes: bytes,
      macho: macho,
      dataOffset: dataOffset,
      commandOffset: commandOffset,
      path: path,
    );
    _updateSignatureLayout(
      code,
      macho,
      commandOffset,
      dataOffset,
      macho.signatureDataSize,
      path,
    );

    // Pass one only measures: the signature covers __LINKEDIT sizes that are
    // not final until the signature's own length is known.
    final provisional = _buildEmbeddedSignature(code, dataOffset, inputs);
    final needed = alignUp(
      provisional.length,
      signatureAlignment,
      path,
      'LC_CODE_SIGNATURE.datasize',
    );
    // An existing signature area is reused whenever it is already big enough,
    // which keeps the file length unchanged.
    final dataSize =
        macho.signatureCommand != null && macho.signatureDataSize >= needed
        ? macho.signatureDataSize
        : needed;
    final finalLength = checkedAdd(
      dataOffset,
      dataSize,
      uint32Max,
      path,
      'final file length',
    );
    writeU32le(
      code,
      commandOffset + CodeSignatureCommand.dataSize,
      dataSize,
      path,
      'LC_CODE_SIGNATURE.datasize',
    );
    _updateLinkedit(code, macho, finalLength, path);

    // Pass two signs the finalized layout. RSA PKCS#1 v1.5 is deterministic in
    // length, so this must land in the space pass one reserved.
    final signature = _buildEmbeddedSignature(code, dataOffset, inputs);
    if (signature.length > dataSize ||
        alignUp(
              signature.length,
              signatureAlignment,
              path,
              'signature length',
            ) !=
            needed) {
      machoFail(path, 'CMS size', 'changed while finalizing the Mach-O layout');
    }
    final output = Uint8List(finalLength)..setRange(0, code.length, code);
    output.setRange(dataOffset, dataOffset + signature.length, signature);
    return output;
  }

  /// Validates the caller's arguments and precomputes everything both signing
  /// passes consume.
  SignatureInputs _collectInputs({
    required MachOLayout macho,
    required String path,
    required String identifier,
    required String teamIdentifier,
    required Map<String, Object?> entitlements,
    required Map<String, Object?>? derEntitlements,
    required Uint8List? infoPlistBytes,
    required Uint8List? infoPlistSha256,
    required Uint8List? codeResourcesBytes,
    required Uint8List? codeResourcesSha256,
    required DateTime? signingTime,
  }) {
    requireSigningString(identifier, 'identifier', path);
    requireSigningString(teamIdentifier, 'team identifier', path);
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
    // Only main executables carry entitlements; libraries get an empty blob.
    final isExecutable = macho.fileType == mhExecute;
    // Built in this order because it decides which error a caller sees when
    // more than one input is malformed.
    final xmlEntitlements = buildEntitlementsXml(
      isExecutable ? entitlements : const {},
      path,
    );
    final derEntitlementsBlob = isExecutable
        ? buildDerEntitlements(derEntitlements ?? entitlements, path)
        : null;
    final requirement = buildRequirements(
      identifier,
      signingAsset.certificateCommonName,
      path,
    );
    return SignatureInputs(
      execSegmentLimit: macho.textVmSize,
      identifier: identifier,
      teamIdentifier: teamIdentifier,
      infoHash: infoHash,
      resourcesHash: resourcesHash,
      requirement: requirement,
      xmlEntitlements: xmlEntitlements,
      derEntitlements: derEntitlementsBlob,
      isExecutable: isExecutable,
      signingTime: signingTime ?? DateTime.now(),
      path: path,
    );
  }

  /// The signature starts where an existing one already does, otherwise at the
  /// next 16-byte boundary past the end of the file.
  static int _signatureDataOffset(
    MachOLayout macho,
    Uint8List bytes,
    String path,
  ) {
    final dataOffset = macho.signatureCommand == null
        ? alignUp(
            bytes.length,
            signatureAlignment,
            path,
            'signature data offset',
          )
        : macho.signatureDataOffset;
    if (dataOffset > uint32Max) {
      machoFail(
        path,
        'signature data offset',
        'exceeds the 32-bit Mach-O field',
      );
    }
    return dataOffset;
  }

  /// Copies the code region, injecting `LC_CODE_SIGNATURE` into the
  /// load-command slack when the input has no signature command yet.
  static Uint8List _buildCodeImage({
    required Uint8List bytes,
    required MachOLayout macho,
    required int dataOffset,
    required int commandOffset,
    required String path,
  }) {
    final code = Uint8List(dataOffset);
    code.setRange(
      0,
      bytes.length < dataOffset ? bytes.length : dataOffset,
      bytes,
    );
    if (macho.signatureCommand != null) return code;

    if (macho.commandSlack < CodeSignatureCommand.size) {
      machoFail(
        path,
        'load-command slack',
        'needs 16 bytes for LC_CODE_SIGNATURE, found ${macho.commandSlack}',
      );
    }
    // Refuse to overwrite anything the linker may still rely on.
    for (
      var index = commandOffset;
      index < commandOffset + CodeSignatureCommand.size;
      index++
    ) {
      if (code[index] != 0) {
        machoFail(path, 'load-command slack', 'contains non-zero data');
      }
    }
    writeU32le(
      code,
      MachHeader64.ncmds,
      macho.ncmds + 1,
      path,
      'mach_header_64.ncmds',
    );
    writeU32le(
      code,
      MachHeader64.sizeofcmds,
      macho.sizeofcmds + CodeSignatureCommand.size,
      path,
      'mach_header_64.sizeofcmds',
    );
    writeU32le(
      code,
      commandOffset + LoadCommand.cmd,
      lcCodeSignature,
      path,
      'cmd',
    );
    writeU32le(
      code,
      commandOffset + LoadCommand.cmdsize,
      CodeSignatureCommand.size,
      path,
      'cmdsize',
    );
    writeU32le(
      code,
      commandOffset + CodeSignatureCommand.dataOffset,
      dataOffset,
      path,
      'LC_CODE_SIGNATURE.dataoff',
    );
    return code;
  }

  static Future<Uint8List> _read(String path) async {
    try {
      return await File(path).readAsBytes();
    } on Object catch (error) {
      throw AppleError('Could not read Mach-O "$path": $error');
    }
  }

  static void _updateSignatureLayout(
    Uint8List code,
    MachOLayout macho,
    int commandOffset,
    int dataOffset,
    int initialDataSize,
    String path,
  ) {
    writeU32le(
      code,
      commandOffset + CodeSignatureCommand.dataOffset,
      dataOffset,
      path,
      'LC_CODE_SIGNATURE.dataoff',
    );
    writeU32le(
      code,
      commandOffset + CodeSignatureCommand.dataSize,
      initialDataSize,
      path,
      'LC_CODE_SIGNATURE.datasize',
    );
    final initialLength = checkedAdd(
      dataOffset,
      initialDataSize,
      uint32Max,
      path,
      'provisional file length',
    );
    _updateLinkedit(code, macho, initialLength, path);
  }

  /// Grows `__LINKEDIT` to cover the signature. `vmsize` is only rounded up
  /// when the file actually grew, so linker output with an unrounded `vmsize`
  /// survives a re-sign that fits in place.
  static void _updateLinkedit(
    Uint8List code,
    MachOLayout macho,
    int finalLength,
    String path,
  ) {
    final fileSize = finalLength - macho.linkeditFileOffset;
    if (fileSize < 0) {
      machoFail(path, '__LINKEDIT.filesize', 'would become negative');
    }
    final growth = finalLength - macho.originalLength;
    final vmSize = growth <= 0
        ? macho.linkeditVmSize
        : alignUp(
            checkedAdd(
              macho.linkeditVmSize,
              growth,
              uint32Max,
              path,
              '__LINKEDIT.vmsize',
            ),
            machoPageSize,
            path,
            '__LINKEDIT.vmsize',
          );
    if (vmSize < fileSize) {
      machoFail(path, '__LINKEDIT.vmsize', 'is smaller than the new filesize');
    }
    writeU64le(
      code,
      macho.linkeditCommand + SegmentCommand64.vmsize,
      vmSize,
      path,
      '__LINKEDIT.vmsize',
    );
    writeU64le(
      code,
      macho.linkeditCommand + SegmentCommand64.filesize,
      fileSize,
      path,
      '__LINKEDIT.filesize',
    );
  }

  /// Assembles the `CS_SuperBlob`: code directory, requirements, entitlements,
  /// and the detached CMS signature over the code directory's hash.
  Uint8List _buildEmbeddedSignature(
    Uint8List code,
    int codeLimit,
    SignatureInputs inputs,
  ) {
    final path = inputs.path;
    final derEntitlements = inputs.derEntitlements;
    final specialSlots = _specialSlots(inputs);
    final execSegmentFlags = _execSegmentFlags(inputs);
    final codeDirectory = buildCodeDirectory(
      code: code,
      codeLimit: codeLimit,
      execSegmentLimit: inputs.execSegmentLimit,
      execSegmentFlags: execSegmentFlags,
      identifier: inputs.identifier,
      teamIdentifier: inputs.teamIdentifier,
      specialSlots: specialSlots,
      path: path,
    );
    final Uint8List cms;
    try {
      cms = signingAsset.buildDetachedCms(
        codeDirectoryBytes: codeDirectory,
        cdhashBytes: sha256Digest(codeDirectory),
        signingTime: inputs.signingTime,
      );
    } on Object catch (error) {
      machoFail(path, 'CMS signature', '$error');
    }
    return buildSuperblob([
      SignatureSlot(type: csslotCodeDirectory, bytes: codeDirectory),
      SignatureSlot(type: csslotRequirements, bytes: inputs.requirement),
      SignatureSlot(type: csslotEntitlements, bytes: inputs.xmlEntitlements),
      if (derEntitlements != null)
        SignatureSlot(type: csslotDerEntitlements, bytes: derEntitlements),
      SignatureSlot(type: csslotSignature, bytes: _cmsWrapper(cms, path)),
    ], path);
  }

  static Uint8List _cmsWrapper(Uint8List cms, String path) =>
      csBlob(csMagicBlobWrapper, cms, path, 'CMS wrapper');

  /// Special slots run from -7 up to -1 and are written in that order, so the
  /// unused -6 and -4 slots must still be present as all-zero hashes.
  static List<Uint8List> _specialSlots(SignatureInputs inputs) {
    final derEntitlements = inputs.derEntitlements;
    return <Uint8List>[
      if (inputs.isExecutable) sha256Digest(derEntitlements!),
      if (inputs.isExecutable) Uint8List(csSha256Length),
      sha256Digest(inputs.xmlEntitlements),
      Uint8List(csSha256Length),
      inputs.resourcesHash,
      sha256Digest(inputs.requirement),
      inputs.infoHash,
    ];
  }

  static int _execSegmentFlags(SignatureInputs inputs) =>
      (inputs.isExecutable ? csExecsegMainBinary : 0) |
      (inputs.isExecutable && entitlementsAllowUnsigned(inputs.xmlEntitlements)
          ? csExecsegAllowUnsigned
          : 0);

  /// Accepts either the source bytes or a precomputed digest, never both, and
  /// falls back to an all-zero slot when the bundle has no such file.
  static Uint8List _hashSource({
    required Uint8List? bytes,
    required Uint8List? hash,
    required String field,
    required String path,
  }) {
    if (bytes != null && hash != null) {
      machoFail(path, field, 'provide bytes or a SHA-256 hash, not both');
    }
    if (hash != null) {
      if (hash.length != csSha256Length) {
        machoFail(path, field, 'SHA-256 hash must be 32 bytes');
      }
      return Uint8List.fromList(hash);
    }
    return bytes == null ? Uint8List(csSha256Length) : sha256Digest(bytes);
  }
}
