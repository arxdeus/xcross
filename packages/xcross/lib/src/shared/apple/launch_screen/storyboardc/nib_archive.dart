import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// One `key → value` pair of a [NibObject].
@internal
@immutable
final class NibValue {
  const NibValue._(this.key, this.type, this.payload);

  const NibValue.int8(String key, int value) : this._(key, 0, value);
  const NibValue.int16(String key, int value) : this._(key, 1, value);
  const NibValue.yes(String key) : this._(key, 5, null);
  const NibValue.float(String key, double value) : this._(key, 6, value);
  const NibValue.double(String key, double value) : this._(key, 7, value);
  const NibValue.nil(String key) : this._(key, 9, null);

  /// A reference to the object at [index] of the archive.
  const NibValue.ref(String key, int index) : this._(key, 10, index);

  NibValue.string(String key, String value)
    : this._(key, 8, Uint8List.fromList(utf8.encode(value)));

  /// Raw bytes given as hex.
  NibValue.data(String key, String hex)
    : this._(key, 8, Uint8List.fromList(_unhex(hex)));

  final String key;

  /// NIBArchive value type tag.
  final int type;
  final Object? payload;

  /// The string payload of a [NibValue.string].
  String? get stringValue =>
      type == 8 ? utf8.decode(payload! as Uint8List) : null;

  static List<int> _unhex(String hex) => [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}

@internal
@immutable
final class NibObject {
  const NibObject(this.className, this.values, {this.superclasses = const []});

  final String className;
  final List<NibValue> values;

  /// Class names recorded as this class's "extras" (its superclass chain).
  final List<String> superclasses;

  NibObject withValues(List<NibValue> newValues) =>
      NibObject(className, newValues, superclasses: superclasses);
}

/// Encoder for Apple's `NIBArchive` container (what `ibtool` writes into a
/// `.storyboardc`). Tables are laid out exactly as `ibtool` lays them out:
/// objects, keys, values, classes, with keys and classes in order of first
/// use, so output is byte-identical to Xcode's for the same object graph.
@internal
final class NibArchiveWriter {
  const NibArchiveWriter._();

  static Uint8List write(List<NibObject> objects) {
    final keys = <String>[];
    final classes = <String>[];
    final classExtras = <String, List<String>>{};
    int keyIndex(String key) {
      var i = keys.indexOf(key);
      if (i < 0) {
        keys.add(key);
        i = keys.length - 1;
      }
      return i;
    }

    int classIndex(String name) {
      var i = classes.indexOf(name);
      if (i < 0) {
        classes.add(name);
        i = classes.length - 1;
      }
      return i;
    }

    for (final o in objects) {
      classIndex(o.className);
      classExtras[o.className] ??= o.superclasses;
    }
    for (final extras in classExtras.values.toList()) {
      extras.forEach(classIndex);
    }

    final objectBytes = BytesBuilder();
    final valueBytes = BytesBuilder();
    var valueCount = 0;
    for (final o in objects) {
      _varint(objectBytes, classIndex(o.className));
      _varint(objectBytes, valueCount);
      _varint(objectBytes, o.values.length);
      for (final v in o.values) {
        valueCount++;
        _varint(valueBytes, keyIndex(v.key));
        _writeValue(valueBytes, v);
      }
    }

    final keyBytes = BytesBuilder();
    for (final k in keys) {
      final b = utf8.encode(k);
      _varint(keyBytes, b.length);
      keyBytes.add(b);
    }
    final classBytes = BytesBuilder();
    for (final c in classes) {
      final b = utf8.encode(c);
      _varint(classBytes, b.length + 1);
      final extras = classExtras[c] ?? const <String>[];
      _varint(classBytes, extras.length);
      for (final e in extras) {
        classBytes.add(_u32(classIndex(e)));
      }
      classBytes
        ..add(b)
        ..addByte(0);
    }

    const headerLength = 50;
    const objectsOffset = headerLength;
    final keysOffset = objectsOffset + objectBytes.length;
    final valuesOffset = keysOffset + keyBytes.length;
    final classesOffset = valuesOffset + valueBytes.length;
    return (BytesBuilder()
          ..add(ascii.encode('NIBArchive'))
          ..add(_u32(1))
          ..add(_u32(10))
          ..add(_u32(objects.length))
          ..add(_u32(objectsOffset))
          ..add(_u32(keys.length))
          ..add(_u32(keysOffset))
          ..add(_u32(valueCount))
          ..add(_u32(valuesOffset))
          ..add(_u32(classes.length))
          ..add(_u32(classesOffset))
          ..add(objectBytes.toBytes())
          ..add(keyBytes.toBytes())
          ..add(valueBytes.toBytes())
          ..add(classBytes.toBytes()))
        .toBytes();
  }

  static void _writeValue(BytesBuilder out, NibValue v) {
    out.addByte(v.type);
    switch (v.type) {
      case 0:
        out.addByte(v.payload! as int);
      case 1:
        out.add(
          (ByteData(2)..setInt16(0, v.payload! as int, Endian.little)).buffer
              .asUint8List(),
        );
      case 6:
        out.add(
          (ByteData(4)..setFloat32(0, v.payload! as double, Endian.little))
              .buffer
              .asUint8List(),
        );
      case 7:
        out.add(
          (ByteData(8)..setFloat64(0, v.payload! as double, Endian.little))
              .buffer
              .asUint8List(),
        );
      case 8:
        final bytes = v.payload! as Uint8List;
        _varint(out, bytes.length);
        out.add(bytes);
      case 10:
        out.add(_u32(v.payload! as int));
      default:
        break;
    }
  }

  static Uint8List _u32(int value) =>
      (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();

  /// NIBArchive varints: 7 bits per byte, little endian, the *terminating*
  /// byte has its high bit set.
  static void _varint(BytesBuilder out, int value) {
    var v = value;
    while (v >= 0x80) {
      out.addByte(v & 0x7f);
      v >>= 7;
    }
    out.addByte(v | 0x80);
  }
}
