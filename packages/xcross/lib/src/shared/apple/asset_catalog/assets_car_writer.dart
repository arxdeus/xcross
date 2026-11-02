import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog.dart';
import 'package:xcross/src/shared/apple/asset_catalog/car/bom_writer.dart';
import 'package:xcross/src/shared/apple/asset_catalog/car/csi_writer.dart';

/// Thrown when an asset cannot be compiled into `Assets.car`.
@internal
final class AssetsCarException implements Exception {
  const AssetsCarException(this.message);

  final String message;

  @override
  String toString() => 'AssetsCarException: $message';
}

/// Compiles an [AssetCatalog] into a CoreUI `Assets.car`, the way `actool`
/// does, in pure Dart so it runs on any host.
///
/// Supported: color sets (all `Contents.json` color spaces, light/dark,
/// idioms), image sets (any format `package:image` decodes, stored as
/// uncompressed premultiplied BGRA bitmaps) and the app icon set named
/// `appIconName` (icon images plus the multi-sized image index). Output is
/// deterministic.
@internal
final class AssetsCarWriter {
  const AssetsCarWriter();

  static const _authoringTool =
      '@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-653.4';
  static const _mainVersion = '@(#)PROGRAM:CoreUI  PROJECT:CoreUI-975';
  static const _versionString = 'xcross';

  Uint8List write(
    AssetCatalog catalog, {
    required Uint8List Function(String path) readFile,
    required int deploymentTargetMajor,
    String? appIconName,
  }) {
    final names = <String>{
      for (final set in catalog.imageSets) set.name,
      for (final set in catalog.colorSets) set.name,
      if (appIconName != null && catalog.appIconSet(appIconName) != null)
        appIconName,
    }.toList()..sort();
    final identifiers = {for (final (i, name) in names.indexed) name: i + 1};
    final facetParts = <String, int>{};
    final renditions = <(Uint8List, Uint8List)>[];
    final appearances = <String, int>{'UIAppearanceAny': 0};

    void add(Map<int, int> attributes, Uint8List csi) {
      final key = ByteData(CarAttribute.keyFormat.length * 2);
      for (final (i, attribute) in CarAttribute.keyFormat.indexed) {
        key.setUint16(i * 2, attributes[attribute] ?? 0, Endian.little);
      }
      renditions.add((key.buffer.asUint8List(), csi));
    }

    int appearanceId(AssetAppearance appearance) {
      switch (appearance) {
        case AssetAppearance.any:
          return 0;
        case AssetAppearance.dark:
          appearances['UIAppearanceDark'] = 1;
          return 1;
        case AssetAppearance.light:
          appearances['UIAppearanceLight'] = 4;
          return 4;
        case AssetAppearance.tinted:
          appearances['ISAppearanceTintable'] = 6;
          return 6;
      }
    }

    for (final set in catalog.colorSets) {
      facetParts[set.name] = CarPart.color;
      for (final entry in set.colors) {
        final color = entry.color;
        final gray =
            color.colorSpace == AssetColorSpace.grayGamma22 ||
            color.colorSpace == AssetColorSpace.extendedGray;
        add(
          {
            CarAttribute.appearance: appearanceId(entry.appearance),
            CarAttribute.scale: 1,
            CarAttribute.idiom: _idiom(entry.idiom),
            CarAttribute.identifier: identifiers[set.name]!,
            CarAttribute.element: CarPart.element,
            CarAttribute.part: CarPart.color,
          },
          CsiWriter.color(
            name: set.name,
            colorSpaceId: _colorSpace(color.colorSpace),
            components: gray
                ? [color.red, color.alpha]
                : [color.red, color.green, color.blue, color.alpha],
          ),
        );
      }
    }

    for (final set in catalog.imageSets) {
      facetParts[set.name] = CarPart.image;
      for (final entry in set.images) {
        add({
          CarAttribute.appearance: appearanceId(entry.appearance),
          CarAttribute.scale: entry.scale,
          CarAttribute.idiom: _idiom(entry.idiom),
          CarAttribute.identifier: identifiers[set.name]!,
          CarAttribute.element: CarPart.element,
          CarAttribute.part: CarPart.image,
        }, _bitmap(set.name, entry.filePath, entry.scale, readFile));
      }
    }

    final iconSet = appIconName == null
        ? null
        : catalog.appIconSet(appIconName);
    if (iconSet != null) {
      facetParts[iconSet.name] = CarPart.iconImage;
      final id = identifiers[iconSet.name]!;
      // Per idiom: the pixel sizes it offers, for the multi-sized index.
      final sizesByIdiom = <int, List<(int, int, int)>>{};
      for (final entry in iconSet.images) {
        if (entry.appearance != AssetAppearance.any) continue;
        if (entry.idiom == AssetIdiom.iosMarketing) continue;
        final idioms = entry.idiom == AssetIdiom.universal
            ? [CarIdiom.phone, CarIdiom.pad]
            : [_idiom(entry.idiom)];
        final bitmap = _bitmap(iconSet.name, entry.filePath, 1, readFile);
        for (final idiom in idioms) {
          final sizes = sizesByIdiom.putIfAbsent(idiom, () => []);
          final index = sizes.length + 1;
          sizes.add((entry.pixelSize, entry.pixelSize, index));
          add({
            CarAttribute.scale: 1,
            CarAttribute.idiom: idiom,
            CarAttribute.dimension2: index,
            CarAttribute.identifier: id,
            CarAttribute.element: CarPart.element,
            CarAttribute.part: CarPart.iconImage,
          }, bitmap);
        }
      }
      for (final MapEntry(key: idiom, value: sizes) in sizesByIdiom.entries) {
        add({
          CarAttribute.scale: 1,
          CarAttribute.idiom: idiom,
          CarAttribute.identifier: id,
          CarAttribute.element: CarPart.element,
          CarAttribute.part: CarPart.multisizedImage,
        }, CsiWriter.multisizedImage(name: iconSet.name, sizes: sizes));
      }
    }

    renditions.sort((a, b) => _compareBytes(a.$1, b.$1));

    final bom = BomWriter();
    bom.addVariable('CARHEADER', bom.addBlock(_carHeader(renditions.length)));
    bom.addVariable('RENDITIONS', bom.addTree(renditions));
    final facets = [
      for (final name in names)
        if (facetParts[name] case final part?)
          (_ascii(name), _facetValue(part, identifiers[name]!)),
    ]..sort((a, b) => _compareBytes(a.$1, b.$1));
    bom.addVariable('FACETKEYS', bom.addTree(facets));
    final appearanceEntries = [
      for (final MapEntry(:key, :value) in appearances.entries)
        (
          _ascii(key),
          Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.little),
        ),
    ]..sort((a, b) => _compareBytes(a.$1, b.$1));
    bom
      ..addVariable('APPEARANCEKEYS', bom.addTree(appearanceEntries))
      ..addVariable('KEYFORMAT', bom.addBlock(_keyFormat()))
      ..addVariable(
        'EXTENDED_METADATA',
        bom.addBlock(_extendedMetadata(deploymentTargetMajor)),
      );
    return bom.build();
  }

  static Uint8List _bitmap(
    String name,
    String path,
    int scale,
    Uint8List Function(String path) readFile,
  ) {
    final decoded = img.decodeImage(readFile(path));
    if (decoded == null) {
      throw AssetsCarException('cannot decode image $path of asset $name');
    }
    final rgba = decoded.convert(numChannels: 4, format: img.Format.uint8);
    final bytes = rgba.getBytes(order: img.ChannelOrder.bgra);
    var opaque = true;
    // Premultiply alpha, as CoreUI expects for ARGB renditions.
    for (var i = 0; i < bytes.length; i += 4) {
      final alpha = bytes[i + 3];
      if (alpha == 255) continue;
      opaque = false;
      for (var c = 0; c < 3; c++) {
        bytes[i + c] = (bytes[i + c] * alpha + 127) ~/ 255;
      }
    }
    final fileName = path.split(RegExp(r'[/\\]')).last;
    return CsiWriter.image(
      name: fileName,
      width: rgba.width,
      height: rgba.height,
      scale: scale,
      opaque: opaque,
      bgra: bytes,
    );
  }

  static int _idiom(AssetIdiom idiom) => switch (idiom) {
    AssetIdiom.universal => CarIdiom.universal,
    AssetIdiom.iphone => CarIdiom.phone,
    AssetIdiom.ipad => CarIdiom.pad,
    AssetIdiom.iosMarketing => CarIdiom.marketing,
    AssetIdiom.car => CarIdiom.car,
    AssetIdiom.watch => CarIdiom.watch,
    AssetIdiom.tv => CarIdiom.tv,
    AssetIdiom.mac => CarIdiom.mac,
    AssetIdiom.vision => CarIdiom.vision,
  };

  static int _colorSpace(AssetColorSpace space) => switch (space) {
    AssetColorSpace.srgb => 1,
    AssetColorSpace.grayGamma22 => 2,
    AssetColorSpace.displayP3 => 3,
    AssetColorSpace.extendedSrgb => 4,
    AssetColorSpace.extendedLinearSrgb => 5,
    AssetColorSpace.extendedGray => 6,
  };

  static Uint8List _facetValue(int part, int identifier) {
    final data = ByteData(18)
      ..setUint16(0, 0, Endian.little) // hot spot x
      ..setUint16(2, 0, Endian.little) // hot spot y
      ..setUint16(4, 3, Endian.little)
      ..setUint16(6, CarAttribute.element, Endian.little)
      ..setUint16(8, CarPart.element, Endian.little)
      ..setUint16(10, CarAttribute.part, Endian.little)
      ..setUint16(12, part, Endian.little)
      ..setUint16(14, CarAttribute.identifier, Endian.little)
      ..setUint16(16, identifier, Endian.little);
    return data.buffer.asUint8List();
  }

  static Uint8List _carHeader(int renditionCount) {
    final header = Uint8List(436);
    header.setRange(0, 4, 'RATC'.codeUnits);
    final data = ByteData.sublistView(header)
      ..setUint32(4, 975, Endian.little) // CoreUI version
      ..setUint32(8, 17, Endian.little) // storage version
      ..setUint32(12, 0, Endian.little) // timestamp (deterministic)
      ..setUint32(16, renditionCount, Endian.little);
    header
      ..setRange(20, 20 + _mainVersion.length, _mainVersion.codeUnits)
      ..setRange(148, 148 + _versionString.length, _versionString.codeUnits);
    data
      ..setUint32(424, 2, Endian.little) // schema version
      ..setUint32(428, 1, Endian.little) // color space: sRGB
      ..setUint32(432, 2, Endian.little); // key semantics
    return header;
  }

  static Uint8List _keyFormat() {
    const format = CarAttribute.keyFormat;
    final data = ByteData(12 + format.length * 4);
    data
      ..setUint32(0, 0x6B666D74, Endian.little) // 'kfmt'
      ..setUint32(4, 0, Endian.little)
      ..setUint32(8, format.length, Endian.little);
    for (final (i, attribute) in format.indexed) {
      data.setUint32(12 + i * 4, attribute, Endian.little);
    }
    return data.buffer.asUint8List();
  }

  static Uint8List _extendedMetadata(int deploymentTargetMajor) {
    final meta = Uint8List(1028);
    meta.setRange(0, 4, 'META'.codeUnits);
    final version = '$deploymentTargetMajor.0';
    meta
      ..setRange(260, 260 + version.length, version.codeUnits)
      ..setRange(516, 519, 'ios'.codeUnits)
      ..setRange(772, 772 + _authoringTool.length, _authoringTool.codeUnits);
    return meta;
  }

  static Uint8List _ascii(String value) => Uint8List.fromList(value.codeUnits);

  static int _compareBytes(Uint8List a, Uint8List b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }
}
