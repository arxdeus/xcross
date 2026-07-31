import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xcross/src/darwinsdk/pbzx_reader.dart';

import 'test_fixtures.dart';

/// Apple's fixed pbzx chunk size (16 MiB) — mirrors the private constant in
/// pbzx_reader.dart; a chunk's `compressedSize` field equal to this exact
/// value is the strict, size-based signal that it's stored raw.
const int _chunkSize = 0x1000000;

Future<List<int>> decodeToBytes(RandomAccessFile file, int length) async {
  final out = BytesBuilder();
  await for (final piece in decodePbzx(file, offset: 0, length: length)) {
    out.add(piece);
  }
  return out.takeBytes();
}

void main() {
  group('decodePbzx', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pbzx_reader_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('decodes a single final xz-compressed chunk', () async {
      final plaintext = utf8.encode(
        'the quick brown fox jumps over the lazy dog',
      );
      final xzBytes = await xzCompress(plaintext);
      final pbzxBytes = buildPbzx([
        // decompressedSize < chunkSize marks this the (only, final) chunk.
        PbzxChunk(decompressedSize: plaintext.length, bytes: xzBytes),
      ]);

      final path = '${tempDir.path}/single.pbzx';
      await File(path).writeAsBytes(pbzxBytes);
      final file = await File(path).open();
      addTearDown(file.close);

      final decoded = await decodeToBytes(file, pbzxBytes.length);
      expect(decoded, plaintext);
    });

    test(
      'decodes multiple consecutive xz chunks via one concatenated decode',
      () async {
        final plain1 = utf8.encode('first chunk payload ' * 100);
        final plain2 = utf8.encode('second chunk payload ' * 100);
        final plain3 = utf8.encode('final chunk');

        final pbzxBytes = buildPbzx([
          // Non-final chunks report the nominal full chunk size regardless
          // of their real (tiny, for-test) decompressed length — the reader
          // never validates decompressedSize against actual output, it only
          // uses it to detect the final chunk.
          PbzxChunk(
            decompressedSize: _chunkSize,
            bytes: await xzCompress(plain1),
          ),
          PbzxChunk(
            decompressedSize: _chunkSize,
            bytes: await xzCompress(plain2),
          ),
          PbzxChunk(
            decompressedSize: plain3.length,
            bytes: await xzCompress(plain3),
          ),
        ]);

        final path = '${tempDir.path}/multi.pbzx';
        await File(path).writeAsBytes(pbzxBytes);
        final file = await File(path).open();
        addTearDown(file.close);

        final decoded = await decodeToBytes(file, pbzxBytes.length);
        expect(decoded, [...plain1, ...plain2, ...plain3]);
      },
    );

    test(
      'copies a raw (compressedSize == 0x1000000) chunk through verbatim, '
      'then decodes the following compressed final chunk',
      () async {
        // A real 16 MiB raw chunk, matching Apple's exact size-based
        // raw-chunk signal (this is a genuinely un-testable-any-smaller
        // path: readExact(compressedSize) requires exactly that many raw
        // bytes to actually be present in the stream).
        final raw = Uint8List(_chunkSize);
        for (var i = 0; i < raw.length; i++) {
          raw[i] = i & 0xff;
        }
        final finalPlain = utf8.encode('tail after the raw chunk');

        final pbzxBytes = buildPbzx([
          PbzxChunk(decompressedSize: _chunkSize, bytes: raw),
          PbzxChunk(
            decompressedSize: finalPlain.length,
            bytes: await xzCompress(finalPlain),
          ),
        ]);

        final path = '${tempDir.path}/raw.pbzx';
        await File(path).writeAsBytes(pbzxBytes);
        final file = await File(path).open();
        addTearDown(file.close);

        final decoded = await decodeToBytes(file, pbzxBytes.length);
        expect(decoded.length, raw.length + finalPlain.length);
        expect(decoded.sublist(0, raw.length), raw);
        expect(decoded.sublist(raw.length), finalPlain);
      },
      timeout: const Timeout.factor(3),
    );

    test(
      'treats a non-full-size chunk that lacks xz magic as raw too '
      '(safety net)',
      () async {
        final notXz = utf8.encode('definitely not an xz stream, just text');
        final finalPlain = utf8.encode('after the bogus chunk');

        final pbzxBytes = buildPbzx([
          PbzxChunk(decompressedSize: _chunkSize, bytes: notXz),
          PbzxChunk(
            decompressedSize: finalPlain.length,
            bytes: await xzCompress(finalPlain),
          ),
        ]);

        final path = '${tempDir.path}/sniff.pbzx';
        await File(path).writeAsBytes(pbzxBytes);
        final file = await File(path).open();
        addTearDown(file.close);

        final decoded = await decodeToBytes(file, pbzxBytes.length);
        expect(decoded, [...notXz, ...finalPlain]);
      },
    );

    test('throws on bad magic', () async {
      final path = '${tempDir.path}/bad.pbzx';
      await File(path).writeAsBytes(utf8.encode('nope' * 8));
      final file = await File(path).open();
      addTearDown(file.close);

      expect(
        decodeToBytes(file, 32),
        throwsA(isException),
      );
    });
  });
}
