import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:test/test.dart';
import 'package:xcross/src/shared/apple/asset_catalog/car/lzfse_writer.dart';

/// Test-side LZFSE decoder for the block kinds [LzfseWriter] emits (`bvxn`,
/// `bvx-`, `bvx$`), implementing the full LZVN opcode table so it also
/// rejects encoder output that would hit an opcode we did not mean to emit.
@internal
abstract final class LzfseTestDecoder {
  static Uint8List decode(Uint8List stream) {
    final out = BytesBuilder();
    final data = ByteData.sublistView(stream);
    var p = 0;
    while (true) {
      final magic = String.fromCharCodes(stream, p, p + 4);
      switch (magic) {
        case r'bvx$':
          return out.toBytes();
        case 'bvx-':
          final n = data.getUint32(p + 4, Endian.little);
          out.add(stream.sublist(p + 8, p + 8 + n));
          p += 8 + n;
        case 'bvxn':
          final raw = data.getUint32(p + 4, Endian.little);
          final size = data.getUint32(p + 8, Endian.little);
          final block = _lzvn(stream.sublist(p + 12, p + 12 + size));
          expect(block.length, raw);
          out.add(block);
          p += 12 + size;
        default:
          fail('unexpected block $magic at $p');
      }
    }
  }

  static Uint8List _lzvn(Uint8List s) {
    final out = <int>[];
    var p = 0;
    var d = 0;
    void copy(int literals, int match, int distance) {
      out.addAll(s.sublist(p, p + literals));
      p += literals;
      if (match > 0) {
        expect(distance, inInclusiveRange(1, out.length));
        for (var i = 0; i < match; i++) {
          out.add(out[out.length - distance]);
        }
      }
    }

    while (true) {
      final op = s[p];
      if (op == 0x06) return Uint8List.fromList(out); // eos
      if (op == 0x0E || op == 0x16) {
        p++; // nop
        continue;
      }
      final low = op & 7;
      if (op >= 0xF0) {
        if (op == 0xF0) {
          final m = s[p + 1] + 16;
          p += 2;
          copy(0, m, d);
        } else {
          p++;
          copy(0, op & 0x0F, d);
        }
      } else if (op >= 0xE0) {
        if (op == 0xE0) {
          final l = s[p + 1] + 16;
          p += 2;
          copy(l, 0, 0);
        } else {
          p++;
          copy(op & 0x0F, 0, 0);
        }
      } else if (op >= 0xA0 && op < 0xC0) {
        // med_d
        final l = (op >> 3) & 3;
        final w = s[p + 1] | s[p + 2] << 8;
        final m = ((op & 7) << 2 | (w & 3)) + 3;
        d = w >> 2;
        p += 3;
        copy(l, m, d);
      } else if (op >= 0x70 && op < 0x80 || op >= 0xD0 && op < 0xE0) {
        fail('undefined LZVN opcode ${op.toRadixString(16)}');
      } else if (low == 7) {
        // lrg_d
        final l = op >> 6;
        final m = ((op >> 3) & 7) + 3;
        d = s[p + 1] | s[p + 2] << 8;
        p += 3;
        copy(l, m, d);
      } else if (low == 6) {
        // pre_d
        final l = op >> 6;
        final m = ((op >> 3) & 7) + 3;
        p++;
        copy(l, m, d);
      } else {
        // sml_d
        final l = op >> 6;
        final m = ((op >> 3) & 7) + 3;
        d = low << 8 | s[p + 1];
        p += 2;
        copy(l, m, d);
      }
    }
  }
}

void main() {
  Uint8List roundTrip(Uint8List data) =>
      LzfseTestDecoder.decode(LzfseWriter.compress(data));

  test('round-trips empty, tiny and incompressible data', () {
    final random = Random(7);
    for (final data in [
      Uint8List(0),
      Uint8List.fromList([1, 2, 3]),
      Uint8List.fromList(List.generate(5000, (_) => random.nextInt(256))),
    ]) {
      expect(roundTrip(data), data);
    }
  });

  test('compresses flat and patterned pixels and round-trips them', () {
    final flat = Uint8List.fromList(
      List.generate(1024 * 64 * 4, (i) => [0, 200, 0, 255][i % 4]),
    );
    final compressed = LzfseWriter.compress(flat);
    expect(compressed.length, lessThan(flat.length ~/ 50));
    expect(LzfseTestDecoder.decode(compressed), flat);

    final random = Random(3);
    final palette = [
      for (var i = 0; i < 4; i++)
        [for (var c = 0; c < 4; c++) random.nextInt(256)],
    ];
    final mixed = Uint8List.fromList([
      for (var i = 0; i < 40000; i++)
        ...palette[(i ~/ (1 + random.nextInt(40))) % 4],
    ]);
    expect(roundTrip(mixed), mixed);
  });
}
