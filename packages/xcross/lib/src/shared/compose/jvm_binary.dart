import 'dart:typed_data';
import 'package:meta/meta.dart';

@internal
int readClassU2(Uint8List buf, int off) => (buf[off] << 8) | buf[off + 1];

@internal
int readClassU4(Uint8List buf, int off) =>
    (buf[off] << 24) |
    (buf[off + 1] << 16) |
    (buf[off + 2] << 8) |
    buf[off + 3];

@internal
Uint8List emitClassU2(int v) => Uint8List.fromList([(v >> 8) & 0xFF, v & 0xFF]);

@internal
Uint8List emitClassU4(int v) => Uint8List.fromList([
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
]);
