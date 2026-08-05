import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:darwin_sdk_kit/src/errors.dart';

/// Fixed size, in bytes, of a classic POSIX portable-ASCII ("odc") cpio
/// entry header — no padding follows it, unlike the binary/newc variants.
const int _headerSize = 76;

/// ASCII magic every odc header starts with.
const String _odcMagic = '070707';

/// Name of the synthetic final entry that marks end-of-archive.
const String _trailerName = 'TRAILER!!!';

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
    final bytes = _ByteCursor(input);

    while (true) {
      final header = ascii.decode(await bytes.take(_headerSize));
      if (!header.startsWith(_odcMagic)) {
        throw DarwinSdkError(
          'cpio: bad magic (expected odc header "$_odcMagic").',
        );
      }
      int octalField(int start, int length) =>
          int.parse(header.substring(start, start + length).trim(), radix: 8);

      final namesize = octalField(_namesizeOffset, 6);
      final filesize = octalField(_filesizeOffset, 11);

      // namesize includes the trailing NUL; strip it before decoding.
      final nameBytes = await bytes.take(namesize);
      final name = ascii.decode(nameBytes.sublist(0, namesize - 1));
      final data = await bytes.take(filesize);

      if (name == _trailerName) return;

      yield CpioEntry(
        name: name,
        mode: octalField(_modeOffset, 6),
        data: data,
        dev: octalField(_devOffset, 6),
        ino: octalField(_inoOffset, 6),
        nlink: octalField(_nlinkOffset, 6),
      );
    }
  }
}

/// Pulls exactly-sized byte runs out of an arbitrarily chunked stream,
/// holding at most one source chunk at a time.
class _ByteCursor {
  _ByteCursor(Stream<List<int>> input) : _chunks = StreamQueue(input);

  final StreamQueue<List<int>> _chunks;
  Uint8List _chunk = Uint8List(0);
  int _offset = 0;

  Future<Uint8List> take(int count) async {
    final out = Uint8List(count);
    var filled = 0;
    while (filled < count) {
      if (_offset >= _chunk.length) await _advance();
      final available = (_chunk.length - _offset).clamp(0, count - filled);
      out.setRange(filled, filled + available, _chunk, _offset);
      _offset += available;
      filled += available;
    }
    return out;
  }

  Future<void> _advance() async {
    if (!await _chunks.hasNext) {
      throw DarwinSdkError('cpio: unexpected end of stream.');
    }
    final next = await _chunks.next;
    _chunk = next is Uint8List ? next : Uint8List.fromList(next);
    _offset = 0;
  }
}
