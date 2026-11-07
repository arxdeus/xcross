import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Minimal `bplist00` writer for what `ibtool` puts in a `.storyboardc`
/// `Info.plist`: nested string-keyed dictionaries of strings and small
/// integers. Objects are numbered the way `plutil` numbers them: a dictionary,
/// then its keys, then its values in order, each nested dictionary taking its
/// own keys and values right after itself.
@internal
final class BinaryPlist {
  const BinaryPlist._();

  static Uint8List write(Map<String, Object> root) {
    final objects = <List<int>?>[];
    final refs = <int, List<int>>{};

    int reserve() {
      objects.add(null);
      return objects.length - 1;
    }

    void emit(int index, Object value) {
      switch (value) {
        case final Map<String, Object> map:
          final keyIdx = [for (final _ in map.keys) reserve()];
          var k = 0;
          for (final key in map.keys) {
            objects[keyIdx[k++]] = _string(key);
          }
          final valIdx = <int>[];
          for (final v in map.values) {
            final i = reserve();
            valIdx.add(i);
            emit(i, v);
          }
          refs[index] = [...keyIdx, ...valIdx];
          objects[index] = _header(0xd0, map.length);
        case final String s:
          objects[index] = _string(s);
        case final int n when n >= 0 && n < 256:
          objects[index] = [0x10, n];
        default:
          throw ArgumentError('Unsupported plist value $value');
      }
    }

    emit(reserve(), root);

    final total = objects.length;
    final refSize = total <= 0xff ? 1 : 2;
    final body = BytesBuilder()..add(ascii.encode('bplist00'));
    final offsets = <int>[];
    for (var i = 0; i < total; i++) {
      offsets.add(body.length);
      body.add(objects[i]!);
      for (final r in refs[i] ?? const <int>[]) {
        if (refSize == 2) body.addByte(r >> 8);
        body.addByte(r & 0xff);
      }
    }
    final tableOffset = body.length;
    final offsetSize = tableOffset <= 0xff ? 1 : 2;
    for (final o in offsets) {
      if (offsetSize == 2) body.addByte(o >> 8);
      body.addByte(o & 0xff);
    }
    final trailer = ByteData(32)
      ..setUint8(6, offsetSize)
      ..setUint8(7, refSize)
      ..setUint64(8, total)
      ..setUint64(24, tableOffset);
    body.add(trailer.buffer.asUint8List());
    return body.toBytes();
  }

  static List<int> _header(int marker, int length) =>
      length < 15 ? [marker | length] : [marker | 0x0f, 0x10, length];

  static List<int> _string(String s) => [
    ..._header(0x50, s.length),
    ...ascii.encode(s),
  ];
}
