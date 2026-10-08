import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

@internal
Uint8List adHocSignedMachO(List<int> payload, {int flags = 0x20002}) {
  const headerSize = 32;
  const commandSize = 16;
  const pageSize = 4096;
  final codeLimit = (headerSize + commandSize + payload.length + 15) & ~15;
  final slots = (codeLimit + pageSize - 1) ~/ pageSize;
  const identifier = [0x66, 0x69, 0x78, 0x74, 0x75, 0x72, 0x65, 0];
  const directoryHeader = 88;
  final hashOffset = directoryHeader + identifier.length;
  final directoryLength = hashOffset + slots * 32;
  final signatureSize = 20 + directoryLength;
  final bytes = Uint8List(codeLimit + signatureSize);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0xFEED_FACF, Endian.little);
  data.setUint32(4, 0x0100_000c, Endian.little);
  data.setUint32(12, 0x6, Endian.little);
  data.setUint32(16, 1, Endian.little);
  data.setUint32(20, commandSize, Endian.little);
  data.setUint32(headerSize, 0x1d, Endian.little);
  data.setUint32(headerSize + 4, commandSize, Endian.little);
  data.setUint32(headerSize + 8, codeLimit, Endian.little);
  data.setUint32(headerSize + 12, signatureSize, Endian.little);
  bytes.setRange(
    headerSize + commandSize,
    headerSize + commandSize + payload.length,
    payload,
  );
  data.setUint32(codeLimit, 0xFADE_0CC0);
  data.setUint32(codeLimit + 4, signatureSize);
  data.setUint32(codeLimit + 8, 1);
  data.setUint32(codeLimit + 12, 0);
  data.setUint32(codeLimit + 16, 20);
  final directory = codeLimit + 20;
  data.setUint32(directory, 0xFADE_0C02);
  data.setUint32(directory + 4, directoryLength);
  data.setUint32(directory + 8, 0x20400);
  data.setUint32(directory + 12, flags);
  data.setUint32(directory + 16, hashOffset);
  data.setUint32(directory + 20, directoryHeader);
  data.setUint32(directory + 28, slots);
  data.setUint32(directory + 32, codeLimit);
  bytes[directory + 36] = 32;
  bytes[directory + 37] = 2;
  bytes[directory + 39] = 12;
  bytes.setRange(
    directory + directoryHeader,
    directory + directoryHeader + identifier.length,
    identifier,
  );
  _writePageHashes(bytes, directory);
  return bytes;
}

@internal
int payloadOffset() => 48;

@internal
List<int> stalePages(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final signature = data.getUint32(40, Endian.little);
  final directory = signature + data.getUint32(signature + 16);
  final hashOffset = data.getUint32(directory + 16);
  final slots = data.getUint32(directory + 28);
  final codeLimit = data.getUint32(directory + 32);
  final stale = <int>[];
  for (var slot = 0; slot < slots; slot++) {
    final start = slot * 4096;
    final end = start + 4096 < codeLimit ? start + 4096 : codeLimit;
    final digest = sha256.convert(bytes.sublist(start, end)).bytes;
    final stored = bytes.sublist(
      directory + hashOffset + slot * 32,
      directory + hashOffset + (slot + 1) * 32,
    );
    for (var index = 0; index < 32; index++) {
      if (digest[index] != stored[index]) {
        stale.add(slot);
        break;
      }
    }
  }
  return stale;
}

void _writePageHashes(Uint8List bytes, int directory) {
  final data = ByteData.sublistView(bytes);
  final hashOffset = data.getUint32(directory + 16);
  final slots = data.getUint32(directory + 28);
  final codeLimit = data.getUint32(directory + 32);
  for (var slot = 0; slot < slots; slot++) {
    final start = slot * 4096;
    final end = start + 4096 < codeLimit ? start + 4096 : codeLimit;
    final digest = sha256.convert(bytes.sublist(start, end)).bytes;
    bytes.setRange(
      directory + hashOffset + slot * 32,
      directory + hashOffset + (slot + 1) * 32,
      digest,
    );
  }
}
