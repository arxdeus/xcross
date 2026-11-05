import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:image/image.dart' as img;
import 'package:meta/meta.dart';

import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog.dart';
import 'package:xcross/src/shared/apple/launch_screen/launch_storyboard_reader.dart';

@internal
@immutable
final class LaunchScreenPlan {
  const LaunchScreenPlan({
    required this.uiLaunchScreen,
    this.synthesizedColor,
    this.warnings = const [],
  });

  /// Value for the `UILaunchScreen` Info.plist key.
  final Map<String, Object?> uiLaunchScreen;

  /// Colorset the caller must add to the catalog (`withColorSet`).
  final ColorSetAsset? synthesizedColor;
  final List<String> warnings;
}

@internal
final class LaunchScreenPlanner {
  /// [fileSystem] is only needed to decode solid-color background images.
  const LaunchScreenPlanner({this.fileSystem});

  static const synthesizedColorName = 'XCrossLaunchBackground';

  final HostFileSystemInterface? fileSystem;

  LaunchScreenPlan plan(LaunchScreenSpec spec, AssetCatalog catalog) {
    final warnings = [
      for (final u in spec.unsupported) 'Launch storyboard: unsupported $u',
    ];
    final ui = <String, Object?>{};
    ColorSetAsset? synthesized;

    final named = spec.backgroundColorName;
    if (named != null && catalog.colorSet(named) != null) {
      ui['UIColorName'] = named;
    } else {
      if (named != null) {
        warnings.add('Launch storyboard: named color "$named" not in catalog');
      }
      var color = spec.backgroundColor;
      final bg = spec.backgroundImageName;
      if (color == null && bg != null) {
        color = _solidColor(catalog, bg);
        if (color == null) {
          warnings.add(
            'Launch storyboard: full-screen image "$bg" is not a solid color',
          );
        }
      }
      if (color != null) {
        synthesized = ColorSetAsset(
          name: synthesizedColorName,
          colors: [ColorSetEntry(color: color)],
        );
        ui['UIColorName'] = synthesizedColorName;
      }
    }

    final image = spec.imageName;
    if (image != null) {
      if (catalog.imageSet(image) != null) {
        ui['UIImageName'] = image;
        if (!spec.imageIsCentered) {
          warnings.add('Launch storyboard: image "$image" is not centered');
        }
      } else {
        warnings.add('Launch storyboard: image "$image" not in asset catalog');
      }
    }
    return LaunchScreenPlan(
      uiLaunchScreen: ui,
      synthesizedColor: synthesized,
      warnings: warnings,
    );
  }

  AssetColor? _solidColor(AssetCatalog catalog, String name) {
    final fs = fileSystem;
    final set = catalog.imageSet(name);
    if (fs == null || set == null || set.images.isEmpty) return null;
    try {
      final entry = set.images.first;
      final decoded = img.decodeImage(
        fs.file(entry.filePath).readAsBytesSync(),
      );
      if (decoded == null || decoded.width * decoded.height > 4096) return null;
      final first = decoded.getPixel(0, 0);
      for (final px in decoded) {
        if (px.r != first.r ||
            px.g != first.g ||
            px.b != first.b ||
            px.a != first.a) {
          return null;
        }
      }
      final max = decoded.maxChannelValue;
      return AssetColor(
        red: first.r / max,
        green: first.g / max,
        blue: first.b / max,
        alpha: first.a / max,
      );
    } on Object {
      return null;
    }
  }
}
