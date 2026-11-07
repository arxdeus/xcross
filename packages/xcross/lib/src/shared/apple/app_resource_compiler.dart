import 'dart:convert';
import 'dart:typed_data';

import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/apple/asset_catalog/app_icon_stager.dart';
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog.dart';
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog_reader.dart';
import 'package:xcross/src/shared/apple/asset_catalog/assets_car_writer.dart';
import 'package:xcross/src/shared/apple/launch_screen/launch_screen_plan.dart';
import 'package:xcross/src/shared/apple/launch_screen/launch_screen_plist.dart';
import 'package:xcross/src/shared/apple/launch_screen/launch_storyboard_reader.dart';
import 'package:xcross/src/shared/apple/launch_screen/storyboardc/launch_storyboard_compiler.dart';
import 'package:xcross/src/shared/artifact/plist_mutations.dart';

/// Compiles an app target's asset catalogs and launch storyboard the way
/// Xcode's `actool` and `ibtool` steps would, in pure Dart, so a bundle built
/// on Linux or Windows has its app icon, launch screen and named images.
///
/// Three outputs, all optional and independent:
///
/// * `Assets.car` in the bundle root, holding every image and color set of
///   the target's catalogs (merged, as `actool` merges them) plus the app
///   icon. `UIImage(named:)`, `UIColor(named:)` and `UILaunchScreen`'s
///   `UIImageName`/`UIColorName` only resolve through it.
/// * Loose `AppIcon60x60@2x.png`-style icons with `CFBundleIcons`, which
///   SpringBoard uses whenever it does not read the icon from `Assets.car`.
/// * The launch storyboard compiled into `Base.lproj/<name>.storyboardc`,
///   the way ibtool does, for the shapes xcross reproduces faithfully (a
///   solid background and at most one image view). Anything else falls back
///   to a `UILaunchScreen` dictionary replacing `UILaunchStoryboardName`.
///
/// Nothing here fails a build: a catalog or storyboard xcross cannot
/// reproduce is reported as a warning and left out, which is what happened to
/// all of them before.
@internal
final class AppResourceCompiler {
  AppResourceCompiler({
    required this.fileSystem,
    required this.paths,
    required this.log,
    AssetsCarWriter carWriter = const AssetsCarWriter(),
  }) : _carWriter = carWriter;

  final HostFileSystemInterface fileSystem;
  final p.Context paths;
  final Log log;
  final AssetsCarWriter _carWriter;

  /// Default `ASSETCATALOG_COMPILER_APPICON_NAME` of Xcode's templates.
  static const defaultAppIconName = 'AppIcon';

  /// Compiles [catalogs] into [bundleDir] and returns [infoPlistXml] with the
  /// icon and launch screen keys applied.
  ///
  /// [launchStoryboard] is the absolute path of the storyboard named by
  /// `UILaunchStoryboardName`, when the project has one and it was not
  /// precompiled. [deviceFamilies] comes from `UIDeviceFamily` (iPhone only
  /// unless the app declares iPad).
  Future<String> compile({
    required String bundleDir,
    required String infoPlistXml,
    required List<String> catalogs,
    required String deploymentTarget,
    String? appIconName,
    List<String> alternateAppIconNames = const [],
    bool includeAllAppIcons = false,
    String? accentColorName,
    String? launchStoryboard,
    Set<AssetIdiom> deviceFamilies = const {AssetIdiom.iphone},
    String? carCacheDirectory,
  }) async {
    var catalog = _readCatalogs(catalogs);
    var xml = infoPlistXml;

    final iconName = appIconName ?? defaultAppIconName;
    final icon = catalog.appIconSet(iconName);
    final alternates = [
      for (final set in catalog.appIconSets)
        if (set.name != iconName &&
            (includeAllAppIcons || alternateAppIconNames.contains(set.name)))
          set,
    ];
    for (final name in alternateAppIconNames) {
      if (catalog.appIconSet(name) == null) {
        log.logWarn(
          'Alternate app icon set "$name" '
          '(ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES) is not in the '
          'asset catalogs; skipping it.',
        );
      }
    }
    if (icon != null) {
      AppIconPlist? icons;
      try {
        icons = await AppIconStager(fileSystem, paths).stage(
          icon,
          bundleDir: bundleDir,
          deviceFamilies: deviceFamilies,
          deploymentTarget: deploymentTarget,
          alternates: alternates,
        );
      } on Object catch (error) {
        log.logWarn('Could not stage app icon "$iconName": $error');
      }
      if (icons == null) {
        // Warned above.
      } else if (_hasIconFiles(icons)) {
        xml = AppIconPlist.applyToInfoPlist(xml, icons);
        log.logTrace('app icon: staged loose "$iconName" icons');
      } else {
        log.logWarn(
          'App icon "$iconName" has no usable iPhone or iPad image; the app '
          'will show a blank icon.',
        );
      }
    } else if (catalogs.isNotEmpty && appIconName != null) {
      log.logWarn(
        'App icon set "$appIconName" (ASSETCATALOG_COMPILER_APPICON_NAME) is '
        'not in the asset catalogs; the app will show a blank icon.',
      );
    }

    if (accentColorName != null && accentColorName.isNotEmpty) {
      if (catalog.colorSet(accentColorName) != null) {
        xml = PlistMutations.setPlistString(
          xml,
          'NSAccentColorName',
          accentColorName,
        );
      } else {
        log.logWarn(
          'Accent color "$accentColorName" '
          '(ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME) is not in the '
          'asset catalogs; NSAccentColorName is not set.',
        );
      }
    }

    if (launchStoryboard != null) {
      final spec = _readLaunchStoryboard(launchStoryboard);
      if (spec != null &&
          _writeCompiledStoryboard(spec, launchStoryboard, bundleDir)) {
        // Native: `UILaunchStoryboardName` stays and points at the compiled
        // `.storyboardc`, exactly as Xcode's ibtool step leaves it.
      } else if (spec != null) {
        final plan = _planLaunchScreen(spec, launchStoryboard, catalog);
        if (plan.synthesizedColor case final ColorSetAsset color) {
          catalog = catalog.withColorSet(color);
        }
        xml = LaunchScreenPlist.apply(xml, plan.uiLaunchScreen);
      }
    }

    if (!catalog.isEmpty) {
      _writeCar(
        catalog,
        bundleDir: bundleDir,
        deploymentTarget: deploymentTarget,
        appIconName: icon == null ? null : iconName,
        alternateAppIconNames: [for (final a in alternates) a.name],
        targetDevices: deviceFamilies,
        cacheDirectory: carCacheDirectory,
      );
    }
    return xml;
  }

  AssetCatalog _readCatalogs(List<String> catalogs) {
    if (catalogs.isEmpty) return const AssetCatalog(path: '');
    final reader = AssetCatalogReader(fileSystem, paths);
    final read = <AssetCatalog>[];
    for (final path in catalogs) {
      final result = reader.read(path);
      final name = paths.basename(path);
      for (final diagnostic in result.diagnostics) {
        log.logWarn('Asset catalog $name: $diagnostic');
      }
      if (result.skipped.isNotEmpty) {
        log.logWarn(
          'Asset catalog $name: skipping ${result.skipped.join(', ')}; '
          'xcross compiles image, color and app icon sets only.',
        );
      }
      read.add(result.catalog);
    }
    return AssetCatalog.merge(catalogs.first, read);
  }

  LaunchScreenSpec? _readLaunchStoryboard(String storyboard) {
    final name = paths.basename(storyboard);
    final LaunchScreenSpec? spec;
    try {
      spec = LaunchStoryboardReader.read(
        fileSystem.file(storyboard).readAsStringSync(),
      );
    } on Object catch (error) {
      log.logWarn('Could not read launch storyboard $name: $error');
      return null;
    }
    if (spec == null) {
      log.logWarn(
        'Launch storyboard $name has no initial view controller xcross can '
        'translate; the app launches with a blank screen.',
      );
    }
    return spec;
  }

  /// Writes the `.storyboardc` ibtool would produce for [spec] next to where
  /// Xcode puts it (`Base.lproj/<name>.storyboardc` for a Base-localized
  /// storyboard, the bundle root otherwise). False when [spec] is outside
  /// the shapes xcross compiles faithfully.
  bool _writeCompiledStoryboard(
    LaunchScreenSpec spec,
    String storyboard,
    String bundleDir,
  ) {
    final compiled = LaunchStoryboardCompiler.compile(spec);
    if (compiled == null) return false;
    final parent = paths.basename(paths.dirname(storyboard));
    final localization = paths.extension(parent) == '.lproj' ? parent : null;
    final directory = paths.joinAll([
      bundleDir,
      ?localization,
      '${paths.basenameWithoutExtension(storyboard)}.storyboardc',
    ]);
    fileSystem.directory(directory).createSync(recursive: true);
    for (final MapEntry(key: name, value: bytes) in compiled.files.entries) {
      fileSystem.file(paths.join(directory, name)).writeAsBytesSync(bytes);
    }
    log.logTrace(
      'launch screen: compiled ${paths.basename(storyboard)} into '
      '${paths.relative(directory, from: bundleDir)}',
    );
    return true;
  }

  LaunchScreenPlan _planLaunchScreen(
    LaunchScreenSpec spec,
    String storyboard,
    AssetCatalog catalog,
  ) {
    final name = paths.basename(storyboard);
    final plan = LaunchScreenPlanner(
      fileSystem: fileSystem,
    ).plan(spec, catalog);
    for (final warning in plan.warnings) {
      log.logWarn('$warning ($name).');
    }
    log.logTrace(
      'launch screen: $name → UILaunchScreen ${plan.uiLaunchScreen}',
    );
    return plan;
  }

  /// Bumped whenever [AssetsCarWriter] output changes for the same inputs,
  /// so stale cached cars are never reused.
  static const carCacheVersion = 1;

  /// Cached cars kept per cache directory (the current one and the previous
  /// one, so toggling between two states stays warm).
  static const carCacheEntries = 2;

  void _writeCar(
    AssetCatalog catalog, {
    required String bundleDir,
    required String deploymentTarget,
    required String? appIconName,
    required List<String> alternateAppIconNames,
    required Set<AssetIdiom> targetDevices,
    required String? cacheDirectory,
  }) {
    final destination = paths.join(bundleDir, 'Assets.car');
    // Like actool's incremental builds: the car only depends on the catalog
    // model, the source image bytes and the options below, so a rebuild
    // with identical inputs reuses the previous output.
    final String? cached;
    try {
      final key = cacheDirectory == null
          ? null
          : carCacheKey(
              catalog,
              deploymentTarget: deploymentTarget,
              appIconName: appIconName,
              alternateAppIconNames: alternateAppIconNames,
              targetDevices: targetDevices,
              readFile: (path) => fileSystem.file(path).readAsBytesSync(),
            );
      cached = key == null ? null : paths.join(cacheDirectory!, '$key.car');
    } on Object catch (error) {
      log.logTrace('Assets.car cache: cannot hash inputs: $error');
      _compileCar(
        catalog,
        destination: destination,
        deploymentTarget: deploymentTarget,
        appIconName: appIconName,
        alternateAppIconNames: alternateAppIconNames,
        targetDevices: targetDevices,
      );
      return;
    }
    if (cached != null && fileSystem.file(cached).existsSync()) {
      fileSystem
          .file(destination)
          .writeAsBytesSync(fileSystem.file(cached).readAsBytesSync());
      log.logTrace('Assets.car: reused ${paths.basename(cached)}');
      return;
    }
    final bytes = _compileCar(
      catalog,
      destination: destination,
      deploymentTarget: deploymentTarget,
      appIconName: appIconName,
      alternateAppIconNames: alternateAppIconNames,
      targetDevices: targetDevices,
    );
    if (bytes == null || cached == null) return;
    try {
      final directory = fileSystem.directory(cacheDirectory!)
        ..createSync(recursive: true);
      fileSystem.file(cached).writeAsBytesSync(bytes);
      final entries =
          directory
              .listSync()
              .where((e) => e.path.endsWith('.car') && e.path != cached)
              .toList()
            ..sort(
              (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
            );
      for (final stale in entries.skip(carCacheEntries - 1)) {
        stale.deleteSync();
      }
    } on Object catch (error) {
      log.logTrace('Assets.car cache: cannot store: $error');
    }
  }

  Uint8List? _compileCar(
    AssetCatalog catalog, {
    required String destination,
    required String deploymentTarget,
    required String? appIconName,
    required List<String> alternateAppIconNames,
    required Set<AssetIdiom> targetDevices,
  }) {
    final Uint8List bytes;
    try {
      bytes = _carWriter.write(
        catalog,
        readFile: (path) => fileSystem.file(path).readAsBytesSync(),
        deploymentTarget: deploymentTarget,
        appIconName: appIconName,
        alternateAppIconNames: alternateAppIconNames,
        targetDevices: targetDevices,
      );
    } on AssetsCarException catch (error) {
      log.logWarn(
        'Could not compile the asset catalog into Assets.car: '
        '${error.message}. Named images, colors and the launch screen image '
        'will be missing.',
      );
      return null;
    }
    fileSystem.file(destination).writeAsBytesSync(bytes);
    log.logTrace(
      'Assets.car: ${catalog.imageSets.length} image sets, '
      '${catalog.colorSets.length} color sets'
      '${appIconName == null ? '' : ', app icon $appIconName'}',
    );
    return bytes;
  }

  /// SHA-256 over everything [AssetsCarWriter.write] reads: the catalog
  /// model in order, the content of every referenced image and the writer
  /// options.
  ///
  /// Image files are hashed by content, not path + mtime: checkouts, copies
  /// and Flutter's own asset tooling rewrite mtimes, and hashing a PNG costs
  /// far less than the decode + LZFSE encode it lets us skip.
  @visibleForTesting
  static String carCacheKey(
    AssetCatalog catalog, {
    required String deploymentTarget,
    required String? appIconName,
    required List<String> alternateAppIconNames,
    required Set<AssetIdiom> targetDevices,
    required Uint8List Function(String path) readFile,
  }) {
    final hashes = <String, String>{};
    String file(String path) =>
        hashes[path] ??= sha256.convert(readFile(path)).toString();
    String color(AssetColor c) =>
        '${c.colorSpace.json} ${c.red} ${c.green} ${c.blue} ${c.alpha}';
    final model = [
      carCacheVersion,
      deploymentTarget,
      appIconName,
      alternateAppIconNames,
      [for (final idiom in AssetIdiom.values) targetDevices.contains(idiom)],
      [
        for (final set in catalog.imageSets)
          [
            set.name,
            for (final e in set.images)
              [file(e.filePath), e.scale, e.idiom.json, e.appearance.name],
          ],
      ],
      [
        for (final set in catalog.colorSets)
          [
            set.name,
            for (final e in set.colors)
              [color(e.color), e.idiom.json, e.appearance.name],
          ],
      ],
      [
        for (final set in catalog.appIconSets)
          if (set.name == appIconName ||
              alternateAppIconNames.contains(set.name))
            [
              set.name,
              for (final e in set.images)
                [
                  file(e.filePath),
                  // Rendition names are file base names.
                  e.filePath.split(RegExp(r'[/\\]')).last,
                  e.size,
                  e.scale,
                  e.idiom.json,
                  e.platform,
                  e.appearance.name,
                ],
            ],
      ],
      // Rendition names of image sets are file base names too.
      [
        for (final set in catalog.imageSets)
          for (final e in set.images) e.filePath.split(RegExp(r'[/\\]')).last,
      ],
    ];
    return sha256.convert(utf8.encode(jsonEncode(model))).toString();
  }

  static bool _hasIconFiles(AppIconPlist icons) {
    bool has(Map<String, Object?>? dict) => switch (dict) {
      {'CFBundlePrimaryIcon': {'CFBundleIconFiles': final List<Object?> files}}
          when files.isNotEmpty =>
        true,
      _ => false,
    };
    return has(icons.cfBundleIcons) || has(icons.cfBundleIconsIpad);
  }

  /// The device families an Info.plist's `UIDeviceFamily` declares.
  static Set<AssetIdiom> deviceFamiliesOf(String infoPlistXml) {
    final array = RegExp(
      r'<key>UIDeviceFamily</key>\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(infoPlistXml);
    if (array == null) return const {AssetIdiom.iphone};
    final values = RegExp(
      r'<(?:integer|string)>\s*(\d+)\s*</',
    ).allMatches(array.group(1)!).map((m) => m.group(1));
    return {
      if (values.contains('1')) AssetIdiom.iphone,
      if (values.contains('2')) AssetIdiom.ipad,
    }.ifEmpty(const {AssetIdiom.iphone});
  }

  /// The storyboard name `UILaunchStoryboardName` (or its `~iphone` variant)
  /// declares, or null.
  static String? launchStoryboardNameOf(String infoPlistXml) => RegExp(
    r'<key>UILaunchStoryboardName(?:~iphone)?</key>\s*<string>([^<]*)</string>',
  ).firstMatch(infoPlistXml)?.group(1)?.trim();
}

extension on Set<AssetIdiom> {
  Set<AssetIdiom> ifEmpty(Set<AssetIdiom> fallback) =>
      isEmpty ? fallback : this;
}
