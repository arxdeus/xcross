/// Shared helpers for building hand-crafted, byte-exact synthetic fixtures
/// for the XAR / pbzx / odc-cpio format layers under test — see the doc
/// comment on `lib/src/darwinsdk/xcode_xip_extractor.dart` for why these
/// tests can't run against a real `Xcode.xip`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Builds a minimal, valid XAR file: 28-byte fixed header + zlib-compressed
/// TOC XML + heap. [entries] maps entry name -> raw heap bytes; each gets a
/// `<file><name>...</name><data>...</data></file>` TOC record with
/// `application/octet-stream` encoding (matching how xip's own `Content`
/// entry is stored — unencoded at the XAR level).
Uint8List buildXar(Map<String, List<int>> entries) {
  final heap = BytesBuilder();
  final fileXml = StringBuffer();
  for (final e in entries.entries) {
    final offset = heap.length;
    heap.add(e.value);
    fileXml.write('''
<file>
  <name>${e.key}</name>
  <data>
    <offset>$offset</offset>
    <length>${e.value.length}</length>
    <size>${e.value.length}</size>
    <encoding style="application/octet-stream"/>
  </data>
</file>
''');
  }
  final tocXml =
      '<?xml version="1.0" encoding="UTF-8"?><xar><toc>$fileXml</toc></xar>';
  final tocCompressed = ZLibEncoder().convert(utf8.encode(tocXml));

  final header = ByteData(28)
    ..setUint32(0, 0x78617221) // "xar!"
    ..setUint16(4, 28) // headerSize
    ..setUint16(6, 1) // version
    ..setUint64(8, tocCompressed.length) // tocLengthCompressed
    ..setUint64(16, utf8.encode(tocXml).length) // tocLengthUncompressed
    ..setUint32(24, 0); // checksumAlg: none

  return Uint8List.fromList([
    ...header.buffer.asUint8List(),
    ...tocCompressed,
    ...heap.takeBytes(),
  ]);
}

/// Builds a pbzx byte stream from a sequence of chunks. Each chunk's
/// `decompressedSize` field is caller-controlled (it's only used by the
/// reader to detect the final chunk / loop termination — the reader never
/// verifies it against actual decompressed length), and `raw` chunks are
/// written as literal bytes rather than `.xz`-compressed ones.
Uint8List buildPbzx(List<PbzxChunk> chunks) {
  final out = BytesBuilder();
  out.add(ascii.encode('pbzx'));
  out.add((ByteData(8)..setUint64(0, 0)).buffer.asUint8List()); // header u64
  for (final c in chunks) {
    out.add(
      (ByteData(8)..setUint64(0, c.decompressedSize)).buffer.asUint8List(),
    );
    out.add(
      (ByteData(8)..setUint64(0, c.bytes.length)).buffer.asUint8List(),
    );
    out.add(c.bytes);
  }
  return out.takeBytes();
}

class PbzxChunk {
  PbzxChunk({required this.decompressedSize, required this.bytes});
  final int decompressedSize;
  final List<int> bytes;
}

/// Compresses [plaintext] into a real, standalone, valid `.xz` file by
/// shelling out to the system `xz` binary — the pbzx reader under test
/// insists on genuine `.xz` container framing (full magic + header/footer),
/// not raw/headerless LZMA1, so a hand-rolled byte array would not exercise
/// the real decode path.
Future<Uint8List> xzCompress(List<int> plaintext) async {
  final process = await Process.start('xz', ['--compress', '--stdout']);
  final stdoutFuture = process.stdout.fold<BytesBuilder>(
    BytesBuilder(),
    (b, chunk) => b..add(chunk),
  );
  process.stdin.add(plaintext);
  await process.stdin.close();
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw StateError('xz --compress failed with exit code $exitCode');
  }
  return (await stdoutFuture).takeBytes();
}

/// Builds one classic POSIX portable-ASCII ("odc") cpio entry: 76-byte
/// fixed-width octal header + NUL-terminated name + raw content, no padding.
Uint8List buildCpioEntry({
  required String name,
  required List<int> data,
  int mode = 0x81a4, // regular file, rw-r--r--
}) {
  final nameBytes = ascii.encode(name);
  final namesize = nameBytes.length + 1; // + trailing NUL
  String oct(int value, int width) => value.toRadixString(8).padLeft(
    width,
    '0',
  );
  final header =
      '070707'
      '${oct(0, 6)}' // dev
      '${oct(0, 6)}' // ino
      '${oct(mode, 6)}'
      '${oct(0, 6)}' // uid
      '${oct(0, 6)}' // gid
      '${oct(1, 6)}' // nlink
      '${oct(0, 6)}' // rdev
      '${oct(0, 11)}' // mtime
      '${oct(namesize, 6)}'
      '${oct(data.length, 11)}';
  return Uint8List.fromList([
    ...ascii.encode(header),
    ...nameBytes,
    0,
    ...data,
  ]);
}

/// The end-of-archive marker odc-cpio entry.
Uint8List buildCpioTrailer() =>
    buildCpioEntry(name: 'TRAILER!!!', data: const []);
