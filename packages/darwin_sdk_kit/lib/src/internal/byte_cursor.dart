import 'dart:async';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:darwin_sdk_kit/src/errors.dart';

/// Pulls exactly-sized byte runs out of an arbitrarily chunked stream,
/// holding at most one source chunk at a time.
final class ByteCursor {
  ByteCursor(Stream<List<int>> input) : _chunks = StreamQueue(input);

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
