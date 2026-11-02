import 'dart:typed_data';

import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/apple/asset_catalog/app_icon_stager.dart';
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog.dart';
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog_reader.dart';
import 'package:xcross/src/shared/apple/asset_catalog/assets_car_writer.dart';
import 'package:xcross/src/shared/apple/launch_screen/launch_screen_plan.dart';
import 'package:xcross/src/shared/apple/launch_screen/launch_screen_plist.dart';
import 'package:xcross/src/shared/apple/launch_screen/launch_storyboard_reader.dart';
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
/// * A `UILaunchScreen` dictionary translated from the launch storyboard,
///   replacing the `UILaunchStoryboardName` that cannot be honored without a
///   compiled `.storyboardc`.
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
      final icons = await AppIconStager(fileSystem, paths).stage(
        icon,
        bundleDir: bundleDir,
        deviceFamilies: deviceFamilies,
        deploymentTarget: deploymentTarget,
        alternates: alternates,
      );
      if (_hasIconFiles(icons)) {
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
      final plan = _planLaunchScreen(launchStoryboard, catalog);
      if (plan != null) {
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

  LaunchScreenPlan? _planLaunchScreen(String storyboard, AssetCatalog catalog) {
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
      return null;
    }
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

  void _writeCar(
    AssetCatalog catalog, {
    required String bundleDir,
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
      return;
    }
    fileSystem
        .file(paths.join(bundleDir, 'Assets.car'))
        .writeAsBytesSync(bytes);
    log.logTrace(
      'Assets.car: ${catalog.imageSets.length} image sets, '
      '${catalog.colorSets.length} color sets'
      '${appIconName == null ? '' : ', app icon $appIconName'}',
    );
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
