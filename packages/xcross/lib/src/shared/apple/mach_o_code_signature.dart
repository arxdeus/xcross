import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/apple/mach_o.dart';

@internal
abstract final class MachOCodeSignature {
  static const _lcCodeSignature = 0x1d;
  static const _superBlobMagic = 0xFADE_0CC0;
  static const _codeDirectoryMagic = 0xFADE_0C02;
  static const _codeDirectorySlot = 0;
  static const _alternateCodeDirectorySlots = 0x1000;
  static const _alternateCodeDirectoryLimit = 0x1005;
  static const _adHocFlag = 0x2;

  static bool refreshAdHocPageHashes(
    Uint8List bytes, {
    required InvalidMachO invalid,
  }) {
    if (bytes.length < MachOConstants.headerSize64 ||
        ByteData.sublistView(bytes).getUint32(0, Endian.little) !=
            MachOConstants.magic64) {
      return false;
    }
    final file = MachOFile.parse(bytes, invalid: invalid);
    MachOLoadCommand? command;
    for (final candidate in file.commands) {
      if (candidate.type == _lcCodeSignature) command = candidate;
    }
    if (command == null) return false;
    if (command.size < 16) {
      invalid('LC_CODE_SIGNATURE is shorter than 16 bytes');
    }
    final dataOffset = file.data.getUint32(command.offset + 8, Endian.little);
    final dataSize = file.data.getUint32(command.offset + 12, Endian.little);
    if (!MachOFile.rangeFits(dataOffset, dataSize, bytes.length) ||
        dataSize < 12) {
      invalid('code signature exceeds file bounds');
    }
    final blob = ByteData.sublistView(bytes, dataOffset, dataOffset + dataSize);
    if (blob.getUint32(0) != _superBlobMagic) return false;
    final count = blob.getUint32(8);
    if (count > (dataSize - 12) ~/ 8) {
      invalid('code signature index exceeds its blob');
    }
    var changed = false;
    for (var index = 0; index < count; index++) {
      final type = blob.getUint32(12 + index * 8);
      if (type != _codeDirectorySlot &&
          (type < _alternateCodeDirectorySlots ||
              type >= _alternateCodeDirectoryLimit)) {
        continue;
      }
      final offset = blob.getUint32(16 + index * 8);
      changed |= _rehash(bytes, dataOffset + offset, dataOffset, invalid);
    }
    return changed;
  }

  static bool _rehash(
    Uint8List bytes,
    int directory,
    int signatureStart,
    InvalidMachO invalid,
  ) {
    if (!MachOFile.rangeFits(directory, 40, bytes.length)) {
      invalid('code directory exceeds file bounds');
    }
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(directory) != _codeDirectoryMagic) return false;
    if (data.getUint32(directory + 12) & _adHocFlag == 0) return false;
    final length = data.getUint32(directory + 4);
    final hashOffset = data.getUint32(directory + 16);
    final slots = data.getUint32(directory + 28);
    final codeLimit = data.getUint32(directory + 32);
    final hashSize = bytes[directory + 36];
    final hash = _hash(bytes[directory + 37]);
    final pageShift = bytes[directory + 39];
    if (hash == null) return false;
    if (codeLimit > signatureStart ||
        !MachOFile.rangeFits(directory, length, bytes.length) ||
        hashOffset + slots * hashSize > length) {
      invalid('code directory has inconsistent bounds');
    }
    final pageSize = pageShift == 0 ? codeLimit : 1 << pageShift;
    var changed = false;
    for (var slot = 0; slot < slots; slot++) {
      final start = slot * pageSize;
      final end = start + pageSize < codeLimit ? start + pageSize : codeLimit;
      final digest = hash
          .convert(Uint8List.sublistView(bytes, start, end))
          .bytes;
      final target = directory + hashOffset + slot * hashSize;
      for (var byte = 0; byte < hashSize; byte++) {
        if (bytes[target + byte] != digest[byte]) {
          bytes[target + byte] = digest[byte];
          changed = true;
        }
      }
    }
    return changed;
  }

  static Hash? _hash(int type) => switch (type) {
    1 => sha1,
    2 || 3 => sha256,
    4 => sha384,
    _ => null,
  };
}
