import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
/// Strategy: consecutive xz-compressed chunks are concatenated and handed to
/// a single `xz --decompress` subprocess per run, since `xz` decodes
/// concatenated/multi-stream `.xz` data by default — this mirrors how
/// Apple's own `pbzx.c` reference tool feeds chunks to liblzma with
/// `LZMA_CONCATENATED`, and avoids spawning one subprocess per chunk (a real
/// Xcode.xip has hundreds of them). A raw chunk (`compressedSize ==
/// 0x1000000`, or one that simply doesn't start with the xz magic bytes —
/// belt-and-braces against a theoretical small incompressible final chunk)
/// breaks that run and is copied through verbatim with no subprocess at all.
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

  final pendingXz = BytesBuilder(copy: false);

  while (pos < end) {
    final decompressedSize = _beUint64(await readExact(8));
    final compressedSize = _beUint64(await readExact(8));
    final chunk = await readExact(compressedSize);

    if (compressedSize == _pbzxChunkSize || !_looksLikeXz(chunk)) {
      yield* _flushXz(pendingXz);
      yield chunk;
    } else {
      pendingXz.add(chunk);
    }

    if (decompressedSize < _pbzxChunkSize) break;
  }

  yield* _flushXz(pendingXz);
}

bool _looksLikeXz(Uint8List chunk) {
  if (chunk.length < _xzMagic.length) return false;
  for (var i = 0; i < _xzMagic.length; i++) {
    if (chunk[i] != _xzMagic[i]) return false;
  }
  return true;
}

int _beUint64(Uint8List bytes) => ByteData.sublistView(bytes).getUint64(0);

Stream<List<int>> _flushXz(BytesBuilder pending) async* {
  if (pending.isEmpty) return;
  yield* _xzDecompress(pending.takeBytes());
}

/// Decompresses one or more concatenated `.xz` streams by shelling out to
/// the `xz` binary, streaming bytes in via stdin and out via stdout so a
/// multi-chunk batch never needs to sit fully in memory as decompressed
/// output.
Stream<List<int>> _xzDecompress(Uint8List compressed) async* {
  // A bare command name (no directory) is resolved by the OS's own PATH
  // search in Process.start on every platform, so this doesn't need
  // ProcessRunner.locateTool's PATH-scanning helper — which assumes a
  // POSIX-style ':'-separated PATH and a `/bin/sh` fallback, neither of
  // which holds on Windows.
  Process process;
  try {
    process = await Process.start('xz', ['--decompress', '--stdout', '--quiet']);
  } on ProcessException catch (e) {
    throw XcrossError("Could not run 'xz' (required to decode Xcode.xip): $e");
  }

  // Write stdin without awaiting completion here: for a large batch, xz can
  // start emitting decompressed output — filling the stdout pipe — before it
  // has finished reading all of stdin, and awaiting the stdin write first
  // would deadlock both sides on a full pipe buffer.
  final stdinDone = process.stdin
      .addStream(Stream.value(compressed))
      .then((_) => process.stdin.close());
  unawaited(stdinDone.catchError((Object _) {}));

  // Drain stderr concurrently too, for the same reason: an error message
  // sitting unread in the stderr pipe could otherwise block xz from exiting
  // while we're still waiting on stdout below.
  final stderrText = process.stderr.transform(utf8.decoder).join();

  yield* process.stdout;

  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw XcrossError('xz exited with code $exitCode: ${await stderrText}');
  }
}
