import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:darwin_sdk_kit/src/errors.dart';

/// Apple's fixed nominal pbzx chunk size (16 MiB). A `compressedSize` field
/// equal to exactly this value marks a chunk stored **raw** (uncompressed).
/// The chunk loop also terminates once a `decompressedSize` strictly less
/// than this is read — that marks the final chunk.
const int _pbzxChunkSize = 0x100_0000;

/// Full `.xz` container magic (not raw/headerless LZMA1).
const List<int> _xzMagic = [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00];

/// `.xz` stream header: 6-byte magic + 2 stream flags + 4-byte CRC32.
const int _xzStreamHeaderSize = 12;

/// LZMA2 control bytes for an uncompressed chunk. `0x01` also resets the
/// dictionary; `0x02` leaves it as-is.
const int _lzma2UncompressedReset = 0x01;
const int _lzma2UncompressedNoReset = 0x02;

/// Decodes the pbzx-framed byte range `[offset, offset + length)` of [file],
/// yielding the fully decompressed payload — a raw cpio stream — as it
/// becomes available.
abstract final class PbzxReader {
  /// Chunks are decoded one at a time by `package:archive`'s pure-Dart
  /// [XZDecoder]: shelling out to a system `xz` would let it batch
  /// consecutive chunks (it decodes concatenated `.xz` streams natively), but
  /// `xz` is not guaranteed on an end user's PATH, especially on Windows.
  /// [XZDecoder] consumes exactly one stream per call, so no batching.
  ///
  /// A raw chunk (`compressedSize == [_pbzxChunkSize]`, or one that simply
  /// doesn't start with the xz magic — belt-and-braces against a theoretical
  /// small incompressible final chunk) is copied through verbatim.
  static Stream<List<int>> decode(
    RandomAccessFile file, {
    required int offset,
    required int length,
  }) async* {
    var pos = offset;
    final end = offset + length;

    Future<Uint8List> readExact(int count) async {
      if (pos + count > end) {
        throw DarwinSdkError(
          'pbzx: chunk extends past declared stream length.',
        );
      }
      await file.setPosition(pos);
      final bytes = await file.read(count);
      if (bytes.length != count) {
        throw DarwinSdkError('pbzx: unexpected end of file.');
      }
      pos += count;
      return bytes;
    }

    final magic = await readExact(4);
    if (String.fromCharCodes(magic) != 'pbzx') {
      throw DarwinSdkError('Not a pbzx stream (bad magic).');
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

  static bool _looksLikeXz(Uint8List chunk) {
    if (chunk.length < _xzMagic.length) return false;
    for (var i = 0; i < _xzMagic.length; i++) {
      if (chunk[i] != _xzMagic[i]) return false;
    }
    return true;
  }

  static int _beUint64(Uint8List bytes) =>
      ByteData.sublistView(bytes).getUint64(0);

  /// Decompresses a single, complete `.xz` stream via `package:archive`'s
  /// pure-Dart [XZDecoder] — no subprocess, no external binary.
  static Uint8List _xzDecompress(Uint8List compressed) {
    try {
      return XZDecoder().decodeBytes(
        _fixInitialLzma2DictionaryReset(compressed),
      );
    } on Object catch (e) {
      throw DarwinSdkError('pbzx: failed to decode an xz-compressed chunk: $e');
    }
  }

  /// `archive` 4.0.9 copies an initial LZMA2 control-1 raw packet to output but
  /// forgets to seed its dictionary. For the first packet of a fresh block,
  /// control 2 is equivalent: the dictionary is already empty, and `archive`
  /// correctly appends those same bytes to it before decoding later matches.
  static Uint8List _fixInitialLzma2DictionaryReset(Uint8List xz) {
    if (xz.length <= _xzStreamHeaderSize) return xz;

    // The block header's first byte is its size in 4-byte units, less one;
    // 0 there means "stream index", not a block.
    final blockHeaderByte = xz[_xzStreamHeaderSize];
    if (blockHeaderByte == 0) return xz;
    final firstControl = _xzStreamHeaderSize + (blockHeaderByte + 1) * 4;
    if (firstControl >= xz.length ||
        xz[firstControl] != _lzma2UncompressedReset) {
      return xz;
    }

    // ponytail: remove when package:archive handles LZMA2 control 1 correctly.
    final fixed = Uint8List.fromList(xz);
    fixed[firstControl] = _lzma2UncompressedNoReset;
    return fixed;
  }
}
