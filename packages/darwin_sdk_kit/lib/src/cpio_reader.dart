import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:darwin_sdk_kit/src/errors.dart';

/// Fixed size, in bytes, of a classic POSIX portable-ASCII ("odc") cpio
/// entry header — no padding follows it, unlike the binary/newc variants.
const int _headerSize = 76;

/// Byte offsets of the fields we care about within the 76-byte odc header:
/// `magic(6) dev(6) ino(6) mode(6) uid(6) gid(6) nlink(6) rdev(6) mtime(11)
/// namesize(6) filesize(11)`.
const int _devOffset = 6;
const int _inoOffset = 12;
const int _modeOffset = 18;
const int _nlinkOffset = 36;
const int _namesizeOffset = 59;
const int _filesizeOffset = 65;

/// One decoded entry from an odc cpio archive.
class CpioEntry {
  const CpioEntry({
    required this.name,
    required this.mode,
    required this.data,
    this.dev = 0,
    this.ino = 0,
    this.nlink = 1,
  });

  /// Entry path, with the trailing NUL and cpio's own end-of-archive marker
  /// (`TRAILER!!!`) already stripped/excluded.
  final String name;

  /// POSIX file mode bits, as stored in the header.
  final int mode;

  final Uint8List data;
  final int dev;
  final int ino;
  final int nlink;
}

/// Reads a classic POSIX portable-ASCII ("odc") cpio stream — NOT "newc" or
/// binary cpio — yielding each entry once its header, name, and content have
/// been fully read.
///
/// Buffers only as many bytes as needed to fill the next fixed-size header
/// or variable-length name/content, so it never holds the whole
/// (potentially multi-GB, once wired to a real Xcode.xip) decompressed
/// archive in memory at once.
abstract final class CpioReader {
  static Stream<CpioEntry> read(Stream<List<int>> input) async* {
    final queue = StreamQueue<List<int>>(input);
    var buffer = Uint8List(0);
    var bufferPos = 0;

    Future<Uint8List> readExact(int count) async {
      final out = Uint8List(count);
      var filled = 0;
      while (filled < count) {
        if (bufferPos >= buffer.length) {
          if (!await queue.hasNext) {
            throw DarwinSdkError('cpio: unexpected end of stream.');
          }
          final next = await queue.next;
          buffer = next is Uint8List ? next : Uint8List.fromList(next);
          bufferPos = 0;
        }
        final take = (buffer.length - bufferPos).clamp(0, count - filled);
        out.setRange(filled, filled + take, buffer, bufferPos);
        bufferPos += take;
        filled += take;
      }
      return out;
    }

    while (true) {
      final header = ascii.decode(await readExact(_headerSize));
      if (!header.startsWith('070707')) {
        throw DarwinSdkError('cpio: bad magic (expected odc header "070707").');
      }
      int field(int start, int len) =>
          int.parse(header.substring(start, start + len).trim(), radix: 8);

      final namesize = field(_namesizeOffset, 6);
      final filesize = field(_filesizeOffset, 11);

      // namesize includes the trailing NUL; strip it before decoding.
      final nameBytes = await readExact(namesize);
      final name = ascii.decode(nameBytes.sublist(0, namesize - 1));
      final data = await readExact(filesize);

      if (name == 'TRAILER!!!') return;

      yield CpioEntry(
        name: name,
        mode: field(_modeOffset, 6),
        data: data,
        dev: field(_devOffset, 6),
        ino: field(_inoOffset, 6),
        nlink: field(_nlinkOffset, 6),
      );
    }
  }
}
