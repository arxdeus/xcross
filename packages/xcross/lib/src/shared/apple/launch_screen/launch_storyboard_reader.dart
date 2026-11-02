import 'package:meta/meta.dart';
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog.dart';
import 'package:xml/xml.dart';

/// What a launch storyboard shows, reduced to what `UILaunchScreen` can
/// express: a background color and one centered image.
@internal
@immutable
final class LaunchScreenSpec {
  const LaunchScreenSpec({
    this.backgroundColor,
    this.backgroundColorName,
    this.imageName,
    this.imageIsCentered = false,
    this.imageContentMode = 'scaleToFill',
    this.backgroundImageName,
    this.unsupported = const [],
  });

  /// Inline background color, when the storyboard has one.
  final AssetColor? backgroundColor;

  /// Named color asset the background references.
  final String? backgroundColorName;

  /// Name of the foreground image.
  final String? imageName;

  /// Whether [imageName] is displayed centered at natural size.
  final bool imageIsCentered;

  /// `contentMode` of the foreground image view.
  final String imageContentMode;

  /// A full-screen image used as background (`flutter_native_splash` style).
  final String? backgroundImageName;

  /// Human readable descriptions of elements that cannot be reproduced.
  final List<String> unsupported;
}

@internal
final class LaunchStoryboardReader {
  const LaunchStoryboardReader._();

  /// Parses [storyboardXml]. Returns null when it is not a readable storyboard.
  static LaunchScreenSpec? read(String storyboardXml) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(storyboardXml);
    } on XmlException {
      return null;
    }
    final root = doc.rootElement;
    final unsupported = <String>[];
    final initialId = root.getAttribute('initialViewController');
    final controller = initialId == null
        ? null
        : root.descendantElements
              .where((e) => e.getAttribute('id') == initialId)
              .firstOrNull;
    final view = controller?.childElements
        .where((e) => e.name.local == 'view' && e.getAttribute('key') == 'view')
        .firstOrNull;
    if (view == null) return null;

    final resources = root.childElements
        .where((e) => e.name.local == 'resources')
        .firstOrNull;

    AssetColor? color;
    String? colorName;
    final colorEl = view.childElements
        .where(
          (e) =>
              e.name.local == 'color' &&
              e.getAttribute('key') == 'backgroundColor',
        )
        .firstOrNull;
    if (colorEl != null) {
      final name = colorEl.getAttribute('name');
      if (name != null) {
        colorName = name;
        final named = resources?.childElements
            .where(
              (e) =>
                  e.name.local == 'namedColor' &&
                  e.getAttribute('name') == name,
            )
            .firstOrNull
            ?.childElements
            .where((e) => e.name.local == 'color')
            .firstOrNull;
        if (named != null) color = _parseColor(named);
      } else if (colorEl.getAttribute('systemColor') != null) {
        final sys = colorEl.getAttribute('systemColor');
        final inner = resources?.childElements
            .where(
              (e) =>
                  e.name.local == 'systemColor' &&
                  e.getAttribute('name') == sys,
            )
            .firstOrNull
            ?.childElements
            .where((e) => e.name.local == 'color')
            .firstOrNull;
        color = inner == null ? null : _parseColor(inner);
        if (color == null) unsupported.add('system color $sys');
      } else {
        color = _parseColor(colorEl);
        if (color == null) unsupported.add('unrecognized background color');
      }
    }

    final constraints = [
      for (final c
          in view.childElements
              .where((e) => e.name.local == 'constraints')
              .expand((e) => e.childElements))
        c,
    ];
    Set<String> attrsOf(String id) => {
      for (final c in constraints)
        if (c.getAttribute('firstItem') == id &&
            (c.getAttribute('secondItem') == null ||
                c.getAttribute('secondItem') == view.getAttribute('id')))
          ?c.getAttribute('firstAttribute'),
    };

    String? imageName;
    var centered = false;
    var imageMode = 'scaleToFill';
    String? backgroundImage;
    final subviews = view.childElements
        .where((e) => e.name.local == 'subviews')
        .expand((e) => e.childElements);
    for (final sub in subviews) {
      final kind = sub.name.local;
      if (kind != 'imageView') {
        unsupported.add(
          kind == 'label' ? 'label "${sub.getAttribute('text') ?? ''}"' : kind,
        );
        continue;
      }
      final cls = sub.getAttribute('customClass');
      if (cls != null) unsupported.add('custom class $cls');
      final image = sub.getAttribute('image');
      if (image == null) continue;
      final mode = sub.getAttribute('contentMode') ?? 'scaleToFill';
      final attrs = attrsOf(sub.getAttribute('id') ?? '');
      final fills =
          {'top', 'bottom', 'leading', 'trailing'}.every(attrs.contains) ||
          {'top', 'bottom', 'left', 'right'}.every(attrs.contains);
      final isCentered =
          attrs.containsAll({'centerX', 'centerY'}) || mode == 'center';
      if (fills && mode != 'center') {
        if (backgroundImage != null) {
          unsupported.add('multiple full-screen images ($image)');
        } else if (mode == 'scaleToFill') {
          backgroundImage = image;
        } else {
          unsupported.add('full-screen image $image with $mode');
        }
      } else if (imageName != null) {
        unsupported.add('multiple images ($image)');
      } else if (mode == 'scaleAspectFill') {
        unsupported.add('image $image with scaleAspectFill');
      } else if (mode == 'scaleToFill' && !isCentered) {
        unsupported.add('image $image with scaleToFill');
      } else {
        imageName = image;
        centered = isCentered;
        imageMode = mode;
        if (!isCentered) unsupported.add('image $image is not centered');
      }
    }

    return LaunchScreenSpec(
      backgroundColor: color,
      backgroundColorName: colorName,
      imageName: imageName,
      imageIsCentered: centered,
      imageContentMode: imageMode,
      backgroundImageName: backgroundImage,
      unsupported: unsupported,
    );
  }

  static AssetColor? _parseColor(XmlElement el) {
    double? n(String a) => double.tryParse(el.getAttribute(a) ?? '');
    final alpha = n('alpha') ?? 1;
    final space = el.getAttribute('colorSpace');
    final custom = el.getAttribute('customColorSpace');
    final white = n('white');
    if (white != null) {
      return AssetColor.gray(white, alpha: alpha);
    }
    final r = n('red');
    final g = n('green');
    final b = n('blue');
    if (r == null || g == null || b == null) return null;
    final isGray = custom == 'genericGamma22GrayColorSpace';
    final cs = switch ((space, custom)) {
      (_, 'displayP3') => AssetColorSpace.displayP3,
      (_, _) when isGray => AssetColorSpace.grayGamma22,
      _ => AssetColorSpace.srgb,
    };
    return AssetColor(red: r, green: g, blue: b, alpha: alpha, colorSpace: cs);
  }
}
