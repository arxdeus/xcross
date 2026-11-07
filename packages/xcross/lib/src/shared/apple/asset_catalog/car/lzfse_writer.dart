import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Writes LZFSE streams made of LZVN (`bvxn`) blocks, the container CoreUI
/// decodes for `lzfse` renditions.
///
/// The LZVN opcode layout follows Apple's open-source lzfse project
/// (https://github.com/lzfse/lzfse, BSD-3-Clause, `lzvn_decode_base.c`);
/// this is an independent, greedy encoder that only emits a subset of the
/// opcodes: `lrg_d` matches, `sml_m` / `lrg_m` match extensions,
/// `sml_l` / `lrg_l` literal runs and the end-of-stream marker.
@internal
abstract final class LzfseWriter {
  static const _minMatch = 3;
  static const _maxDistance = 0xFFFF;
  static const _hashBits = 14;

  /// [data] as an LZFSE stream: one `bvxn` block followed by `bvx$`.
  static Uint8List compress(Uint8List data) {
    final payload = lzvn(data);
    final out = BytesBuilder(copy: false)
      ..add('bvxn'.codeUnits)
      ..add(_u32(data.length))
      ..add(_u32(payload.length))
      ..add(payload)
      ..add(r'bvx$'.codeUnits);
    return out.toBytes();
  }

  /// [data] as a raw LZVN opcode stream, terminated by the end-of-stream
  /// opcode.
  static Uint8List lzvn(Uint8List data) {
    final out = BytesBuilder();
    final table = Int32List(1 << _hashBits)..fillRange(0, 1 << _hashBits, -1);
    var literalStart = 0;
    var previousDistance = -1;
    var i = 0;
    final end = data.length;

    int hash(int at) {
      final v =
          data[at] |
          data[at + 1] << 8 |
          data[at + 2] << 16 |
          data[at + 3] << 24;
      return ((v * 2654435761) & 0xFFFFFFFF) >> (32 - _hashBits);
    }

    while (i + 4 <= end) {
      // Try the previous distance (cheap to extend), then a hashed
      // candidate.
      var distance = 0;
      var length = 0;
      if (previousDistance > 0 && i - previousDistance >= 0) {
        length = _matchLength(data, i - previousDistance, i);
        if (length >= _minMatch) distance = previousDistance;
      }
      final h = hash(i);
      final candidate = table[h];
      table[h] = i;
      if (candidate >= 0 && i - candidate <= _maxDistance) {
        final candidateLength = _matchLength(data, candidate, i);
        if (candidateLength >= _minMatch && candidateLength > length + 1) {
          length = candidateLength;
          distance = i - candidate;
        }
      }
      if (length < _minMatch) {
        i++;
        continue;
      }

      // Literals go in their own runs and every match is an `lrg_d` with no
      // literals and a 3..10 byte head: those opcode bytes (0x07..0x3F) never
      // collide with the other opcode families.
      final literals = i - literalStart;
      if (literals > 0) _literals(out, data, literalStart, literals);
      final first = length > 10 ? 10 : length;
      out
        ..addByte((first - 3) << 3 | 7)
        ..addByte(distance & 0xFF)
        ..addByte(distance >> 8);
      var rest = length - first;
      while (rest > 0) {
        if (rest >= 16) {
          final run = rest > 271 ? 271 : rest;
          out
            ..addByte(0xF0)
            ..addByte(run - 16);
          rest -= run;
        } else {
          out.addByte(0xF0 | rest);
          rest = 0;
        }
      }
      previousDistance = distance;
      // Index a few positions inside the match to find later repeats.
      final matchEnd = i + length;
      for (
        var k = i + 1;
        k < matchEnd && k + 4 <= end;
        k += 1 + (length >> 4)
      ) {
        table[hash(k)] = k;
      }
      i = matchEnd;
      literalStart = i;
    }

    _literals(out, data, literalStart, end - literalStart);
    out
      ..addByte(0x06)
      ..add(Uint8List(7));
    return out.toBytes();
  }

  static int _matchLength(Uint8List data, int from, int at) {
    var n = 0;
    while (at + n < data.length && data[from + n] == data[at + n]) {
      n++;
    }
    return n;
  }

  static void _literals(BytesBuilder out, Uint8List data, int start, int n) {
    for (var at = start; at < start + n; at += 271) {
      final left = start + n - at;
      _literalRun(out, data, at, left > 271 ? 271 : left);
    }
  }

  static void _literalRun(BytesBuilder out, Uint8List data, int start, int n) {
    if (n < 16) {
      out.addByte(0xE0 | n);
    } else {
      out
        ..addByte(0xE0)
        ..addByte(n - 16);
    }
    out.add(Uint8List.sublistView(data, start, start + n));
  }

  static Uint8List _u32(int value) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);
}
