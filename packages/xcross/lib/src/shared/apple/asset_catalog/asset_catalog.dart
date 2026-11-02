import 'package:meta/meta.dart';

/// The parts of an Xcode asset catalog (`.xcassets`) xcross can ship without
/// Apple's `actool`: image sets, color sets and app icon sets.
///
/// This is the hand-off between the catalog reader (which parses the
/// `Contents.json` files), the loose app icon stager, the `Assets.car` writer
/// and the launch screen planner. Everything here is plain data: paths are
/// absolute host paths, and nothing is read until a consumer needs the bytes.
@internal
@immutable
final class AssetCatalog {
  const AssetCatalog({
    required this.path,
    this.imageSets = const [],
    this.colorSets = const [],
    this.appIconSets = const [],
  });

  /// Merges several catalogs of one target, the way `actool` compiles every
  /// catalog of a target into a single `Assets.car`. Earlier catalogs win on
  /// a name clash.
  factory AssetCatalog.merge(String path, Iterable<AssetCatalog> catalogs) {
    final images = <String, ImageSetAsset>{};
    final colors = <String, ColorSetAsset>{};
    final icons = <String, AppIconSetAsset>{};
    for (final catalog in catalogs) {
      for (final set in catalog.imageSets) {
        images.putIfAbsent(set.name, () => set);
      }
      for (final set in catalog.colorSets) {
        colors.putIfAbsent(set.name, () => set);
      }
      for (final set in catalog.appIconSets) {
        icons.putIfAbsent(set.name, () => set);
      }
    }
    return AssetCatalog(
      path: path,
      imageSets: images.values.toList(),
      colorSets: colors.values.toList(),
      appIconSets: icons.values.toList(),
    );
  }

  /// Absolute path of the `.xcassets` directory this was read from.
  final String path;
  final List<ImageSetAsset> imageSets;
  final List<ColorSetAsset> colorSets;
  final List<AppIconSetAsset> appIconSets;

  bool get isEmpty =>
      imageSets.isEmpty && colorSets.isEmpty && appIconSets.isEmpty;

  ImageSetAsset? imageSet(String name) =>
      imageSets.where((set) => set.name == name).firstOrNull;

  ColorSetAsset? colorSet(String name) =>
      colorSets.where((set) => set.name == name).firstOrNull;

  AppIconSetAsset? appIconSet(String name) =>
      appIconSets.where((set) => set.name == name).firstOrNull;

  /// A copy with [colorSet] added, replacing any set of the same name. Used to
  /// synthesize a launch screen background from a storyboard's inline color.
  AssetCatalog withColorSet(ColorSetAsset colorSet) => AssetCatalog(
    path: path,
    imageSets: imageSets,
    colorSets: [
      for (final existing in colorSets)
        if (existing.name != colorSet.name) existing,
      colorSet,
    ],
    appIconSets: appIconSets,
  );
}

/// Device idiom an asset entry targets (`Contents.json` `idiom`).
@internal
enum AssetIdiom {
  universal('universal'),
  iphone('iphone'),
  ipad('ipad'),
  iosMarketing('ios-marketing'),
  car('car'),
  watch('watch'),
  tv('tv'),
  mac('mac'),
  vision('vision');

  const AssetIdiom(this.json);

  /// The value used in `Contents.json`.
  final String json;

  static AssetIdiom? tryParse(String? value) =>
      values.where((idiom) => idiom.json == value).firstOrNull;
}

/// Light/dark variant of an entry (`Contents.json` `appearances`).
@internal
enum AssetAppearance { any, light, dark, tinted }

/// Color space of an [AssetColor] (`Contents.json` `color-space`).
@internal
enum AssetColorSpace {
  srgb('srgb'),
  displayP3('display-p3'),
  extendedSrgb('extended-srgb'),
  extendedLinearSrgb('extended-linear-srgb'),
  grayGamma22('gray-gamma-22'),
  extendedGray('extended-gray');

  const AssetColorSpace(this.json);

  final String json;

  static AssetColorSpace? tryParse(String? value) =>
      values.where((space) => space.json == value).firstOrNull;
}

/// One color, components normalized to `0.0..1.0` (extended ranges allowed).
@internal
@immutable
final class AssetColor {
  const AssetColor({
    required this.red,
    required this.green,
    required this.blue,
    this.alpha = 1,
    this.colorSpace = AssetColorSpace.srgb,
  });

  /// A gray color (`white`, `alpha`) as Interface Builder writes it.
  const AssetColor.gray(double white, {double alpha = 1})
    : this(
        red: white,
        green: white,
        blue: white,
        alpha: alpha,
        colorSpace: AssetColorSpace.grayGamma22,
      );

  final double red;
  final double green;
  final double blue;
  final double alpha;
  final AssetColorSpace colorSpace;

  @override
  bool operator ==(Object other) =>
      other is AssetColor &&
      other.red == red &&
      other.green == green &&
      other.blue == blue &&
      other.alpha == alpha &&
      other.colorSpace == colorSpace;

  @override
  int get hashCode => Object.hash(red, green, blue, alpha, colorSpace);

  @override
  String toString() =>
      'AssetColor(${colorSpace.json} r=$red g=$green b=$blue a=$alpha)';
}

/// An `.imageset`.
@internal
@immutable
final class ImageSetAsset {
  const ImageSetAsset({required this.name, required this.images});

  /// Asset name: the directory name without `.imageset` (namespaced folders
  /// prefix it with `Folder/`).
  final String name;
  final List<ImageSetEntry> images;
}

/// One file slot of an `.imageset`. Slots without a file are dropped by the
/// reader, so [filePath] always names an existing file.
@internal
@immutable
final class ImageSetEntry {
  const ImageSetEntry({
    required this.filePath,
    this.scale = 1,
    this.idiom = AssetIdiom.universal,
    this.appearance = AssetAppearance.any,
  });

  final String filePath;

  /// 1, 2 or 3. A single-scale (vector/PDF style) entry is reported as 1.
  final int scale;
  final AssetIdiom idiom;
  final AssetAppearance appearance;
}

/// A `.colorset`.
@internal
@immutable
final class ColorSetAsset {
  const ColorSetAsset({required this.name, required this.colors});

  final String name;
  final List<ColorSetEntry> colors;
}

@internal
@immutable
final class ColorSetEntry {
  const ColorSetEntry({
    required this.color,
    this.idiom = AssetIdiom.universal,
    this.appearance = AssetAppearance.any,
  });

  final AssetColor color;
  final AssetIdiom idiom;
  final AssetAppearance appearance;
}

/// An `.appiconset`.
@internal
@immutable
final class AppIconSetAsset {
  const AppIconSetAsset({required this.name, required this.images});

  /// Icon set name, e.g. `AppIcon` (`ASSETCATALOG_COMPILER_APPICON_NAME`).
  final String name;
  final List<AppIconEntry> images;
}

/// One file slot of an `.appiconset`. Slots without a file are dropped.
@internal
@immutable
final class AppIconEntry {
  const AppIconEntry({
    required this.filePath,
    required this.size,
    this.scale = 1,
    this.idiom = AssetIdiom.universal,
    this.platform,
    this.appearance = AssetAppearance.any,
  });

  final String filePath;

  /// Edge length in points (`60` for `60x60`, `83.5` for `83.5x83.5`,
  /// `1024` for the single-size format).
  final double size;
  final int scale;
  final AssetIdiom idiom;

  /// `ios` for the Xcode 14+ single-size universal icon, otherwise null.
  final String? platform;
  final AssetAppearance appearance;

  /// Edge length in pixels.
  int get pixelSize => (size * scale).round();
}
