import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:xcross/src/util/errors.dart';

/// Apple's fixed nominal pbzx chunk size (16 MiB). A `compressedSize` field
/// equal to exactly this value marks a chunk stored **raw** (uncompressed).
/// The chunk loop also terminates once a `decompressedSize` strictly less
/// than this is read — that marks the final chunk.
const int _pbzxChunkSize = 0x1000000;

/// Full `.xz` container magic (not raw/headerless LZMA1).
const List<int> _xzMagic = [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00];

/// Decodes the pbzx-framed byte range `[offset, offset + length)` of [file],
/// yielding the fully decompressed payload — a raw cpio stream — as it
/// becomes available.
///
/// Each xz-compressed chunk is decoded independently via `package:archive`'s
/// pure-Dart [XZDecoder] — no external `xz`/`7z` binary required. (An
/// earlier version of this shelled out to a system `xz`, batching
/// consecutive compressed chunks into one subprocess call since `xz` decodes
/// concatenated multi-stream `.xz` data by default — but that meant xcross
/// silently depended on `xz` being present on PATH, which isn't guaranteed
/// on a end user's machine, especially Windows. `XZDecoder.decode` only
/// consumes a single stream per call, not concatenated ones, so chunks are
/// decoded one at a time instead of batched — fine now that there's no
/// subprocess-spawn cost to amortize.) A raw chunk (`compressedSize ==
/// 0x1000000`, or one that simply doesn't start with the xz magic bytes —
/// belt-and-braces against a theoretical small incompressible final chunk)
/// is copied through verbatim with no decompression at all.
Stream<List<int>> decodePbzx(
  RandomAccessFile file, {
  required int offset,
  required int length,
}) async* {
  var pos = offset;
  final end = offset + length;

  Future<Uint8List> readExact(int count) async {
    if (pos + count > end) {
      throw XcrossError('pbzx: chunk extends past declared stream length.');
    }
    await file.setPosition(pos);
    final bytes = await file.read(count);
    if (bytes.length != count) {
      throw XcrossError('pbzx: unexpected end of file.');
    }
    pos += count;
    return bytes;
  }

  final magic = await readExact(4);
  if (String.fromCharCodes(magic) != 'pbzx') {
    throw XcrossError('Not a pbzx stream (bad magic).');
  }
  // Initial header u64: bit 24 is documented as a continuation flag, but the
  // per-chunk `decompressedSize < _pbzxChunkSize` check below is sufficient
  // on its own, so the value itself is read and discarded.
  await readExact(8);

  while (pos < end) {
    final decompressedSize = _beUint64(await readExact(8));
    final compressedSize = _beUint64(await readExact(8));
    final chunk = await readExact(compressedSize);

    if (compressedSize == _pbzxChunkSize || !_looksLikeXz(chunk)) {
      yield chunk;
    } else {
      yield _xzDecompress(chunk);
    }

    if (decompressedSize < _pbzxChunkSize) break;
  }
}

bool _looksLikeXz(Uint8List chunk) {
  if (chunk.length < _xzMagic.length) return false;
  for (var i = 0; i < _xzMagic.length; i++) {
    if (chunk[i] != _xzMagic[i]) return false;
  }
  return true;
}

int _beUint64(Uint8List bytes) => ByteData.sublistView(bytes).getUint64(0);

/// Decompresses a single, complete `.xz` stream via `package:archive`'s
/// pure-Dart [XZDecoder] — no subprocess, no external binary.
Uint8List _xzDecompress(Uint8List compressed) {
  try {
    return XZDecoder().decodeBytes(compressed);
  } on Object catch (e) {
    throw XcrossError('pbzx: failed to decode an xz-compressed chunk: $e');
  }
}
