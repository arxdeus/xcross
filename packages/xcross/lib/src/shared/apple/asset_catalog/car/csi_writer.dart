import 'dart:typed_data';

import 'package:meta/meta.dart';

/// CoreUI rendition key attributes (`kCRTheme*Name`) xcross writes.
@internal
abstract final class CarAttribute {
  static const element = 1;
  static const part = 2;
  static const appearance = 7;
  static const dimension2 = 9;
  static const scale = 12;
  static const localization = 13;
  static const idiom = 15;
  static const subtype = 16;
  static const identifier = 17;

  /// The key format every rendition key follows, in token order. Matches
  /// what `actool` emits for iOS catalogs.
  static const keyFormat = [
    appearance,
    localization,
    scale,
    idiom,
    subtype,
    dimension2,
    identifier,
    element,
    part,
  ];
}

/// `kCRThemeIdiom*` values.
@internal
abstract final class CarIdiom {
  static const universal = 0;
  static const phone = 1;
  static const pad = 2;
  static const tv = 3;
  static const car = 4;
  static const watch = 5;
  static const marketing = 6;
  static const mac = 7;
  static const vision = 8;
}

/// Element/part numbers `actool` uses for the asset kinds xcross writes.
@internal
abstract final class CarPart {
  static const element = 85;
  static const image = 181;
  static const color = 217;
  static const multisizedImage = 218;
  static const iconImage = 220;
}

/// CSI rendition layouts.
@internal
abstract final class CarLayout {
  static const image = 12;
  static const color = 1009;
  static const multisizedImage = 1010;
}

/// Encodes CSI (`CTSI`) rendition blobs, the values of the `RENDITIONS` tree.
///
/// All CSI fields are little-endian.
@internal
abstract final class CsiWriter {
  static const _headerSize = 184;

  /// A bitmap rendition holding [bgra] (premultiplied BGRA, row-major,
  /// uncompressed) of [width]x[height] pixels.
  static Uint8List image({
    required String name,
    required int width,
    required int height,
    required int scale,
    required bool opaque,
    required Uint8List bgra,
  }) {
    final tlv = _Le()
      // Slices: one slice covering the whole image.
      ..u32(0x3E9)
      ..u32(20)
      ..u32(1)
      ..u32(0)
      ..u32(0)
      ..u32(width)
      ..u32(height)
      // Metrics: no insets, full image size.
      ..u32(0x3EB)
      ..u32(28)
      ..u32(1)
      ..u32(0)
      ..u32(0)
      ..u32(0)
      ..u32(0)
      ..u32(width)
      ..u32(height)
      // Composition: normal blend, opacity 1.
      ..u32(0x3EC)
      ..u32(8)
      ..u32(0)
      ..f32(1)
      // EXIF orientation: up.
      ..u32(0x3EE)
      ..u32(4)
      ..u32(1)
      // Bitmap info flags as written by actool.
      ..u32(0x3EF)
      ..u32(4)
      ..u32(0x20);
    final payload = _Le()
      ..ascii('MLEC')
      ..u32(0) // flags
      ..u32(0) // compression: uncompressed
      ..u32(bgra.length)
      ..bytes(bgra);
    return _rendition(
      name: name,
      // Bit 4 is set by actool for bitmap images, bit 3 marks opaque.
      flags: 0x10 | (opaque ? 0x08 : 0),
      width: width,
      height: height,
      scale: scale * 100,
      pixelFormat: 0x41524742, // 'ARGB'
      colorSpace: 1,
      layout: CarLayout.image,
      tlv: tlv.toBytes(),
      payload: payload.toBytes(),
    );
  }

  /// A color rendition. [colorSpaceId] is CoreUI's color space number and
  /// [components] include alpha last.
  static Uint8List color({
    required String name,
    required int colorSpaceId,
    required List<double> components,
  }) {
    final payload = _Le()
      ..ascii('RLOC')
      ..u32(1) // version
      ..u32(colorSpaceId)
      ..u32(components.length);
    components.forEach(payload.f64);
    return _rendition(
      name: name,
      flags: 0,
      width: 0,
      height: 0,
      scale: 0,
      pixelFormat: 0,
      colorSpace: 0,
      layout: CarLayout.color,
      tlv: _plainTlv(),
      payload: payload.toBytes(),
    );
  }

  /// A multi-sized image (app icon) rendition listing the pixel sizes of its
  /// icon images; each size is `(width, height, dimension2 index)`.
  static Uint8List multisizedImage({
    required String name,
    required List<(int, int, int)> sizes,
  }) {
    final payload = _Le()
      ..ascii('SISM')
      ..u32(1)
      ..u32(sizes.length);
    for (final (width, height, index) in sizes) {
      payload
        ..u32(width)
        ..u32(height)
        ..u16(index)
        ..u16(0);
    }
    return _rendition(
      name: name,
      flags: 0,
      width: 0,
      height: 0,
      scale: 0,
      pixelFormat: 0,
      colorSpace: 0,
      layout: CarLayout.multisizedImage,
      tlv: _plainTlv(),
      payload: payload.toBytes(),
    );
  }

  static Uint8List _plainTlv() =>
      (_Le()
            ..u32(0x3EC)
            ..u32(8)
            ..u32(0)
            ..u32(0)
            ..u32(0x3EE)
            ..u32(4)
            ..u32(1))
          .toBytes();

  static Uint8List _rendition({
    required String name,
    required int flags,
    required int width,
    required int height,
    required int scale,
    required int pixelFormat,
    required int colorSpace,
    required int layout,
    required Uint8List tlv,
    required Uint8List payload,
  }) {
    final nameBytes = Uint8List(128);
    final encoded = _utf8(name);
    nameBytes.setRange(0, encoded.length.clamp(0, 127), encoded);
    final out = _Le()
      ..ascii('ISTC')
      ..u32(1) // version
      ..u32(flags)
      ..u32(width)
      ..u32(height)
      ..u32(scale)
      ..u32(pixelFormat)
      ..u32(colorSpace)
      ..u32(0) // modification time
      ..u16(layout)
      ..u16(0)
      ..bytes(nameBytes)
      ..u32(tlv.length)
      ..u32(1) // bitmap count
      ..u32(0) // reserved
      ..u32(payload.length);
    assert(out.length == _headerSize, 'CSI header must be 184 bytes');
    out
      ..bytes(tlv)
      ..bytes(payload);
    return out.toBytes();
  }

  static Uint8List _utf8(String value) {
    final units = <int>[];
    for (final rune in value.runes) {
      if (rune < 0x80) {
        units.add(rune);
      } else if (rune < 0x800) {
        units.addAll([0xC0 | rune >> 6, 0x80 | rune & 0x3F]);
      } else if (rune < 0x10000) {
        units.addAll([
          0xE0 | rune >> 12,
          0x80 | rune >> 6 & 0x3F,
          0x80 | rune & 0x3F,
        ]);
      } else {
        units.addAll([
          0xF0 | rune >> 18,
          0x80 | rune >> 12 & 0x3F,
          0x80 | rune >> 6 & 0x3F,
          0x80 | rune & 0x3F,
        ]);
      }
    }
    return Uint8List.fromList(units);
  }
}

/// Little-endian byte sink.
final class _Le {
  final BytesBuilder _builder = BytesBuilder();
  final ByteData _scratch = ByteData(8);

  int get length => _builder.length;

  void u16(int value) {
    _scratch.setUint16(0, value, Endian.little);
    _builder.add(_scratch.buffer.asUint8List(0, 2));
  }

  void u32(int value) {
    _scratch.setUint32(0, value, Endian.little);
    _builder.add(_scratch.buffer.asUint8List(0, 4));
  }

  void f32(double value) {
    _scratch.setFloat32(0, value, Endian.little);
    _builder.add(_scratch.buffer.asUint8List(0, 4));
  }

  void f64(double value) {
    _scratch.setFloat64(0, value, Endian.little);
    _builder.add(_scratch.buffer.asUint8List(0, 8));
  }

  void ascii(String value) => _builder.add(value.codeUnits);

  void bytes(List<int> value) => _builder.add(value);

  Uint8List toBytes() => _builder.toBytes();
}
