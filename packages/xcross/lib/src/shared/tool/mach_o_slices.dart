import 'dart:typed_data';

(int, int)? arm64SliceRange(Uint8List bytes) {
  if (bytes.length < 8) return null;
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(0) != 0xcafebabe) return null;
  final count = data.getUint32(4);
  if (count > (bytes.length - 8) ~/ 20) return null;
  for (var index = 0; index < count; index++) {
    final base = 8 + index * 20;
    if (data.getUint32(base) != 0x0100000c) continue;
    final offset = data.getUint32(base + 8);
    final length = data.getUint32(base + 12);
    if (offset > bytes.length || length > bytes.length - offset) return null;
    return (offset, offset + length);
  }
  return null;
}
