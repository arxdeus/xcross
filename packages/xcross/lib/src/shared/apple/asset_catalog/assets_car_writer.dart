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
/// `appIconName` and alternate icon sets, laid out like `actool` (icon
/// images per slot, scale and appearance plus the per-idiom multi-sized
/// image index). Output is
/// deterministic.
@internal
base class AssetsCarWriter {
  const AssetsCarWriter();

  static const _authoringTool =
      '@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-653.4';
  static const _mainVersion = '@(#)PROGRAM:CoreUI  PROJECT:CoreUI-975';
  static const _versionString = 'xcross';
  static const _xrSubtype = 1792;

  Uint8List write(
    AssetCatalog catalog, {
    required Uint8List Function(String path) readFile,
    required String deploymentTarget,
    String? appIconName,
    Iterable<String> alternateAppIconNames = const [],
    Set<AssetIdiom> targetDevices = const {AssetIdiom.iphone, AssetIdiom.ipad},
  }) {
    final platformVersion = deploymentTarget;
    final iconSets = <AppIconSetAsset>[
      for (final name in {?appIconName, ...alternateAppIconNames})
        ?catalog.appIconSet(name),
    ];
    final names = <String>{
      for (final set in catalog.imageSets) set.name,
      for (final set in catalog.colorSets) set.name,
      for (final set in iconSets) set.name,
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
          appearances['ISAppearanceTintable'] = 10;
          return 10;
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

    for (final iconSet in iconSets) {
      facetParts[iconSet.name] = CarPart.iconImage;
      _addIconSet(
        iconSet,
        identifier: identifiers[iconSet.name]!,
        targetDevices: targetDevices,
        readFile: readFile,
        appearanceId: appearanceId,
        add: add,
      );
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
        bom.addBlock(_extendedMetadata(platformVersion)),
      );
    return bom.build();
  }

  /// Adds the renditions `actool` writes for an app icon set: one icon image
  /// per slot (keyed by idiom, scale, appearance and the slot's icon index)
  /// and, per idiom, a multi-sized image listing the point sizes it offers.
  ///
  /// The icon index of a slot is the rank of its point size among all point
  /// sizes of the set. Universal (single-size) slots go to iPhone, and to
  /// iPad when it is a target device.
  static void _addIconSet(
    AppIconSetAsset set, {
    required int identifier,
    required Set<AssetIdiom> targetDevices,
    required Uint8List Function(String path) readFile,
    required int Function(AssetAppearance) appearanceId,
    required void Function(Map<int, int>, Uint8List) add,
  }) {
    // actool reuses the iPhone 60pt@3x icon as a 90pt@2x icon of subtype
    // 1792 (the iPhone XR class display) and ranks 90 among the sizes.
    final xrSource = set.images
        .where(
          (e) =>
              e.idiom == AssetIdiom.iphone &&
              e.size == 60 &&
              e.scale == 3 &&
              e.appearance == AssetAppearance.any,
        )
        .firstOrNull;
    final pointSizes = {
      for (final entry in set.images) entry.size,
      if (xrSource != null) 90.0,
    }.toList()..sort();
    int indexOf(double size) => pointSizes.indexOf(size) + 1;
    final sizesByIdiom = <int, Map<double, int>>{};
    final bitmaps = <String, Uint8List>{};
    for (final entry in set.images) {
      final idioms = switch (entry.idiom) {
        AssetIdiom.universal => [
          CarIdiom.phone,
          if (targetDevices.contains(AssetIdiom.ipad)) CarIdiom.pad,
        ],
        final idiom => [_idiom(idiom)],
      };
      final bitmap = bitmaps[entry.filePath] ??= _bitmap(
        set.name,
        entry.filePath,
        entry.scale,
        readFile,
        icon: true,
      );
      for (final idiom in idioms) {
        if (entry.appearance == AssetAppearance.any) {
          sizesByIdiom.putIfAbsent(idiom, () => {})[entry.size] = indexOf(
            entry.size,
          );
        }
        add({
          CarAttribute.appearance: appearanceId(entry.appearance),
          CarAttribute.scale: entry.scale,
          CarAttribute.idiom: idiom,
          CarAttribute.dimension2: indexOf(entry.size),
          CarAttribute.identifier: identifier,
          CarAttribute.element: CarPart.element,
          CarAttribute.part: CarPart.iconImage,
        }, bitmap);
      }
    }
    if (xrSource != null) {
      final index = indexOf(90);
      add({
        CarAttribute.scale: 2,
        CarAttribute.idiom: CarIdiom.phone,
        CarAttribute.subtype: _xrSubtype,
        CarAttribute.dimension2: index,
        CarAttribute.identifier: identifier,
        CarAttribute.element: CarPart.element,
        CarAttribute.part: CarPart.iconImage,
      }, bitmaps[xrSource.filePath]!);
      add({
        CarAttribute.scale: 1,
        CarAttribute.idiom: CarIdiom.phone,
        CarAttribute.subtype: _xrSubtype,
        CarAttribute.identifier: identifier,
        CarAttribute.element: CarPart.element,
        CarAttribute.part: CarPart.multisizedImage,
      }, CsiWriter.multisizedImage(name: set.name, sizes: [(90, 90, index)]));
    }
    for (final MapEntry(key: idiom, value: sizes) in sizesByIdiom.entries) {
      final sorted = sizes.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      add(
        {
          CarAttribute.scale: 1,
          CarAttribute.idiom: idiom,
          CarAttribute.identifier: identifier,
          CarAttribute.element: CarPart.element,
          CarAttribute.part: CarPart.multisizedImage,
        },
        CsiWriter.multisizedImage(
          name: set.name,
          sizes: [
            // actool truncates fractional point sizes (83.5 -> 83).
            for (final MapEntry(key: size, value: index) in sorted)
              (size.truncate(), size.truncate(), index),
          ],
        ),
      );
    }
  }

  static Uint8List _bitmap(
    String name,
    String path,
    int scale,
    Uint8List Function(String path) readFile, {
    bool icon = false,
  }) {
    img.Image? decoded;
    try {
      decoded = img.decodeImage(readFile(path));
    } on Object catch (error) {
      throw AssetsCarException(
        'cannot read image $path of asset $name: $error',
      );
    }
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
      icon: icon,
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

  static Uint8List _extendedMetadata(String version) {
    final meta = Uint8List(1028);
    meta.setRange(0, 4, 'META'.codeUnits);
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
