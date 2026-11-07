import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:meta/meta.dart';
import 'package:test/test.dart';
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog.dart';
import 'package:xcross/src/shared/apple/asset_catalog/assets_car_writer.dart';

import 'lzfse_writer_test.dart';

/// Minimal BOM reader used only to check the writer's output.
@internal
final class BomTestReader {
  BomTestReader(this.bytes) : data = ByteData.sublistView(bytes) {
    expect(String.fromCharCodes(bytes, 0, 8), 'BOMStore');
    final indexOffset = data.getUint32(16);
    final count = data.getUint32(indexOffset);
    for (var i = 0; i < count; i++) {
      blocks.add((
        data.getUint32(indexOffset + 4 + i * 8),
        data.getUint32(indexOffset + 8 + i * 8),
      ));
    }
    var p = data.getUint32(24);
    final varCount = data.getUint32(p);
    p += 4;
    for (var i = 0; i < varCount; i++) {
      final index = data.getUint32(p);
      final length = bytes[p + 4];
      variables[String.fromCharCodes(bytes, p + 5, p + 5 + length)] = index;
      p += 5 + length;
    }
  }

  final Uint8List bytes;
  final ByteData data;
  final List<(int, int)> blocks = [];
  final Map<String, int> variables = {};

  Uint8List block(int index) {
    final (offset, length) = blocks[index];
    return Uint8List.sublistView(bytes, offset, offset + length);
  }

  Uint8List variable(String name) => block(variables[name]!);

  List<(Uint8List, Uint8List)> tree(String name) {
    final tree = ByteData.sublistView(variable(name));
    expect(tree.getUint32(0), 0x74726565);
    final paths = ByteData.sublistView(block(tree.getUint32(8)));
    expect(paths.getUint16(0), 1, reason: 'single leaf');
    return [
      for (var i = 0; i < paths.getUint16(2); i++)
        (
          block(paths.getUint32(16 + i * 8)),
          block(paths.getUint32(12 + i * 8)),
        ),
    ];
  }
}

int _u16(Uint8List b, int o) =>
    ByteData.sublistView(b).getUint16(o, Endian.little);
int _u32(Uint8List b, int o) =>
    ByteData.sublistView(b).getUint32(o, Endian.little);

/// Key token value for kCRThemeXxx in the writer's key format.
int _token(Uint8List key, int position) => _u16(key, position * 2);

const _scalePos = 2;
const _idiomPos = 3;
const _appearancePos = 0;
const _dimension2Pos = 5;
const _identifierPos = 6;
const _subtypePos = 4;
const _partPos = 8;

/// `(point size, icon index)` pairs of a multi-sized image rendition.
List<(int, int)> _sizes(Uint8List csi) {
  final sism = csi.sublist(184 + _u32(csi, 168));
  return [
    for (var i = 0; i < _u32(sism, 8); i++)
      (_u32(sism, 12 + i * 12), _u16(sism, 20 + i * 12)),
  ];
}

/// `(MLEC flags, decoded BGRA)` of an LZFSE bitmap rendition, checking the
/// `KCBC` chunk layout actool uses.
(int, Uint8List) _pixels(Uint8List csi) {
  final payload = csi.sublist(184 + _u32(csi, 168));
  expect(String.fromCharCodes(payload, 0, 4), 'MLEC');
  expect(_u32(payload, 8), 4, reason: 'lzfse');
  final out = BytesBuilder();
  var p = 16;
  for (var i = 0; i < _u32(payload, 12); i++) {
    expect(String.fromCharCodes(payload, p, p + 4), 'KCBC');
    final length = _u32(payload, p + 16);
    out.add(LzfseTestDecoder.decode(payload.sublist(p + 20, p + 20 + length)));
    p += 20 + length;
  }
  expect(p, payload.length);
  return (_u32(payload, 4), out.toBytes());
}

Uint8List _png(int width, int height, List<int> rgba) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgba(x, y, rgba[0], rgba[1], rgba[2], rgba[3]);
    }
  }
  return img.encodePng(image);
}

void main() {
  final files = {
    '/c/Launch.imageset/a.png': _png(40, 20, [255, 0, 0, 255]),
    '/c/Launch.imageset/b.png': _png(80, 40, [0, 0, 255, 128]),
    '/c/AppIcon.appiconset/icon.png': _png(16, 16, [0, 200, 0, 255]),
    '/c/bad.png': Uint8List.fromList([1, 2, 3]),
  };
  Uint8List read(String path) => files[path]!;

  const catalog = AssetCatalog(
    path: '/c',
    imageSets: [
      ImageSetAsset(
        name: 'Launch',
        images: [
          ImageSetEntry(filePath: '/c/Launch.imageset/a.png'),
          ImageSetEntry(
            filePath: '/c/Launch.imageset/b.png',
            scale: 2,
            appearance: AssetAppearance.dark,
          ),
        ],
      ),
    ],
    colorSets: [
      ColorSetAsset(
        name: 'Background',
        colors: [
          ColorSetEntry(color: AssetColor(red: 0.2, green: 0.4, blue: 0.6)),
          ColorSetEntry(color: AssetColor.gray(0.5), idiom: AssetIdiom.ipad),
        ],
      ),
    ],
    appIconSets: [
      AppIconSetAsset(
        name: 'AppIcon',
        images: [
          AppIconEntry(
            filePath: '/c/AppIcon.appiconset/icon.png',
            size: 16,
            platform: 'ios',
          ),
        ],
      ),
    ],
  );

  Uint8List write({String? appIconName = 'AppIcon'}) =>
      const AssetsCarWriter().write(
        catalog,
        readFile: read,
        deploymentTarget: '15.0',
        appIconName: appIconName,
      );

  test('writes a BOM store with the CoreUI variables', () {
    final bom = BomTestReader(write());
    expect(bom.variables.keys, [
      'CARHEADER',
      'RENDITIONS',
      'FACETKEYS',
      'APPEARANCEKEYS',
      'KEYFORMAT',
      'EXTENDED_METADATA',
    ]);
    final header = bom.variable('CARHEADER');
    expect(String.fromCharCodes(header, 0, 4), 'RATC');
    expect(_u32(header, 4), 975);
    expect(_u32(header, 16), bom.tree('RENDITIONS').length);
    final keyFormat = bom.variable('KEYFORMAT');
    expect(String.fromCharCodes(keyFormat, 0, 4), 'tmfk');
    expect(_u32(keyFormat, 8), 9);
    final meta = bom.variable('EXTENDED_METADATA');
    expect(String.fromCharCodes(meta, 260, 264), '15.0');
    expect(String.fromCharCodes(meta, 516, 519), 'ios');
  });

  test('is deterministic', () {
    expect(write(), write());
  });

  test('names every asset in FACETKEYS with its identifier', () {
    final bom = BomTestReader(write());
    final facets = {
      for (final (key, value) in bom.tree('FACETKEYS'))
        String.fromCharCodes(key): value,
    };
    expect(facets.keys, ['AppIcon', 'Background', 'Launch']);
    expect(_u16(facets['Background']!, 12), 217);
    expect(_u16(facets['Launch']!, 12), 181);
    expect(_u16(facets['AppIcon']!, 12), 220);

    final appearances = {
      for (final (key, value) in bom.tree('APPEARANCEKEYS'))
        String.fromCharCodes(key): _u16(value, 0),
    };
    expect(appearances, {'UIAppearanceAny': 0, 'UIAppearanceDark': 1});
  });

  test('encodes renditions in sorted key order with CSI headers', () {
    final bom = BomTestReader(write());
    final renditions = bom.tree('RENDITIONS');
    final keys = [for (final (key, _) in renditions) key];
    for (var i = 1; i < keys.length; i++) {
      expect(_compare(keys[i - 1], keys[i]), lessThan(0));
    }
    for (final (_, csi) in renditions) {
      expect(String.fromCharCodes(csi, 0, 4), 'ISTC');
    }

    final colors = [
      for (final (key, csi) in renditions)
        if (_token(key, _partPos) == 217) (key, csi),
    ];
    expect(colors, hasLength(2));
    final (srgbKey, srgb) = colors.firstWhere(
      (c) => _token(c.$1, _idiomPos) == 0,
    );
    expect(_u16(srgb, 36), 1009);
    expect(String.fromCharCodes(srgb, 40, 50), 'Background');
    final payload = srgb.sublist(184 + _u32(srgb, 168));
    expect(String.fromCharCodes(payload, 0, 4), 'RLOC');
    expect(_u32(payload, 8), 1, reason: 'sRGB');
    final components = ByteData.sublistView(payload, 16);
    expect(components.getFloat64(0, Endian.little), 0.2);
    expect(components.getFloat64(24, Endian.little), 1.0);
    expect(_token(srgbKey, _scalePos), 1);
    final gray = colors.firstWhere((c) => _token(c.$1, _idiomPos) == 2).$2;
    expect(_u32(gray.sublist(184 + _u32(gray, 168)), 8), 2);
  });

  test('stores image set bitmaps as premultiplied BGRA', () {
    final renditions = BomTestReader(write()).tree('RENDITIONS');
    final images = [
      for (final (key, csi) in renditions)
        if (_token(key, _partPos) == 181) (key, csi),
    ];
    expect(images, hasLength(2));
    final (key1, one) = images.firstWhere((i) => _token(i.$1, _scalePos) == 1);
    expect(_token(key1, _appearancePos), 0);
    expect(_u32(one, 12), 40);
    expect(_u32(one, 16), 20);
    expect(_u32(one, 20), 100);
    expect(String.fromCharCodes(one, 24, 28), 'BGRA');
    expect(_u16(one, 36), 12);
    final (flags, pixels) = _pixels(one);
    expect(flags, 3, reason: 'opaque');
    expect(pixels, hasLength(40 * 20 * 4));
    expect(pixels.sublist(0, 4), [0, 0, 255, 255]);

    final (key2, two) = images.firstWhere((i) => _token(i.$1, _scalePos) == 2);
    expect(_token(key2, _appearancePos), 1);
    expect(_u32(two, 20), 200);
    final (flags2, pixels2) = _pixels(two);
    expect(flags2, 1);
    expect(pixels2.sublist(0, 4), [128, 0, 0, 128]);
  });

  test('writes the app icon for iPhone and iPad plus a size index', () {
    final renditions = BomTestReader(write()).tree('RENDITIONS');
    final icons = [
      for (final (key, csi) in renditions)
        if (_token(key, _partPos) == 220) (key, csi),
    ];
    expect([for (final (k, _) in icons) _token(k, _idiomPos)], [1, 2]);
    expect([for (final (k, _) in icons) _token(k, _dimension2Pos)], [1, 1]);
    final index = [
      for (final (key, csi) in renditions)
        if (_token(key, _partPos) == 218) csi,
    ];
    expect(index, hasLength(2));
    final sism = index.first.sublist(184 + _u32(index.first, 168));
    expect(String.fromCharCodes(sism, 0, 4), 'SISM');
    expect(_u32(sism, 12), 16);
    final ids = {for (final (k, _) in icons) _token(k, _identifierPos)};
    expect(ids, hasLength(1));
  });

  test('lays out a legacy icon set like actool', () {
    const slots = [
      (AssetIdiom.iphone, 20.0, 2),
      (AssetIdiom.iphone, 60.0, 2),
      (AssetIdiom.iphone, 60.0, 3),
      (AssetIdiom.ipad, 76.0, 2),
      (AssetIdiom.ipad, 83.5, 2),
      (AssetIdiom.iosMarketing, 1024.0, 1),
    ];
    final legacyFiles = <String, Uint8List>{
      for (final (idiom, size, scale) in slots)
        '/l/${idiom.json}-$size@$scale.png': _png(
          (size * scale).round(),
          (size * scale).round(),
          [0, 0, 0, 255],
        ),
    };
    final car = const AssetsCarWriter().write(
      AssetCatalog(
        path: '/l',
        appIconSets: [
          AppIconSetAsset(
            name: 'AppIcon',
            images: [
              for (final (idiom, size, scale) in slots)
                AppIconEntry(
                  filePath: '/l/${idiom.json}-$size@$scale.png',
                  size: size,
                  scale: scale,
                  idiom: idiom,
                ),
            ],
          ),
        ],
      ),
      readFile: (path) => legacyFiles[path]!,
      deploymentTarget: '13.0',
      appIconName: 'AppIcon',
    );
    final renditions = BomTestReader(car).tree('RENDITIONS');
    // (idiom, scale, subtype, icon index, pixel width)
    final icons = {
      for (final (key, csi) in renditions)
        if (_token(key, _partPos) == 220)
          (
            _token(key, _idiomPos),
            _token(key, _scalePos),
            _token(key, _subtypePos),
            _token(key, _dimension2Pos),
            _u32(csi, 12),
          ),
    };
    // Point sizes ranked: 20, 60, 76, 83.5, 90 (synthesized), 1024.
    expect(icons, {
      (1, 2, 0, 1, 40),
      (1, 2, 0, 2, 120),
      (1, 3, 0, 2, 180),
      (2, 2, 0, 3, 152),
      (2, 2, 0, 4, 167),
      (6, 1, 0, 6, 1024),
      (1, 2, 1792, 5, 180),
    });
    final multiSized = {
      for (final (key, csi) in renditions)
        if (_token(key, _partPos) == 218)
          (_token(key, _idiomPos), _token(key, _subtypePos)): _sizes(csi),
    };
    expect(multiSized, {
      (1, 0): [(20, 1), (60, 2)],
      (1, 1792): [(90, 5)],
      (2, 0): [(76, 3), (83, 4)],
      (6, 0): [(1024, 6)],
    });
  });

  test('writes single-size appearances, iPad only when targeted, and '
      'alternate icons', () {
    final single = <String, Uint8List>{
      for (final name in ['any', 'dark', 'tinted', 'red'])
        '/s/$name.png': _png(4, 4, [9, 9, 9, 255]),
    };
    AppIconSetAsset set(String name, List<(String, AssetAppearance)> files) =>
        AppIconSetAsset(
          name: name,
          images: [
            for (final (file, appearance) in files)
              AppIconEntry(
                filePath: '/s/$file.png',
                size: 1024,
                platform: 'ios',
                appearance: appearance,
              ),
          ],
        );
    final catalog = AssetCatalog(
      path: '/s',
      appIconSets: [
        set('AppIcon', [
          ('any', AssetAppearance.any),
          ('dark', AssetAppearance.dark),
          ('tinted', AssetAppearance.tinted),
        ]),
        set('AppIconRed', [('red', AssetAppearance.any)]),
        set('Unused', [('red', AssetAppearance.any)]),
      ],
    );
    Uint8List build(Set<AssetIdiom> devices) => const AssetsCarWriter().write(
      catalog,
      readFile: (path) => single[path]!,
      deploymentTarget: '16.4',
      appIconName: 'AppIcon',
      alternateAppIconNames: ['AppIconRed'],
      targetDevices: devices,
    );

    final both = BomTestReader(build({AssetIdiom.iphone, AssetIdiom.ipad}));
    expect(
      String.fromCharCodes(both.variable('EXTENDED_METADATA'), 260, 264),
      '16.4',
    );
    final facets = [
      for (final (key, _) in both.tree('FACETKEYS')) String.fromCharCodes(key),
    ];
    expect(facets, ['AppIcon', 'AppIconRed']);
    expect(
      {
        for (final (key, value) in both.tree('APPEARANCEKEYS'))
          String.fromCharCodes(key): _u16(value, 0),
      },
      {'ISAppearanceTintable': 10, 'UIAppearanceAny': 0, 'UIAppearanceDark': 1},
    );
    final icons = {
      for (final (key, _) in both.tree('RENDITIONS'))
        if (_token(key, _partPos) == 220)
          (
            _token(key, _identifierPos),
            _token(key, _idiomPos),
            _token(key, _appearancePos),
            _token(key, _dimension2Pos),
          ),
    };
    expect(icons, hasLength(8));
    expect(icons.map((i) => i.$3).toSet(), {0, 1, 10});
    expect(icons.map((i) => i.$4).toSet(), {1});

    final phoneOnly = BomTestReader(build({AssetIdiom.iphone}));
    expect(
      phoneOnly.tree('RENDITIONS').where((r) => _token(r.$1, _idiomPos) == 2),
      isEmpty,
    );
  });

  test('omits the app icon unless it is requested', () {
    final renditions = BomTestReader(
      write(appIconName: null),
    ).tree('RENDITIONS');
    expect(
      renditions.where((r) => {218, 220}.contains(_token(r.$1, _partPos))),
      isEmpty,
    );
  });

  test('rejects undecodable images', () {
    expect(
      () => const AssetsCarWriter().write(
        const AssetCatalog(
          path: '/c',
          imageSets: [
            ImageSetAsset(
              name: 'Bad',
              images: [ImageSetEntry(filePath: '/c/bad.png')],
            ),
          ],
        ),
        readFile: read,
        deploymentTarget: '15.0',
      ),
      throwsA(isA<AssetsCarException>()),
    );
  });
}

int _compare(Uint8List a, Uint8List b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}
