import 'dart:typed_data';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:image/image.dart' as img;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/apple/asset_catalog/asset_catalog.dart';
import 'package:xcross/src/shared/artifact/plist_mutations.dart';

/// `CFBundleIcons` / `CFBundleIcons~ipad` produced by [AppIconStager].
@internal
@immutable
final class AppIconPlist {
  const AppIconPlist({required this.cfBundleIcons, this.cfBundleIconsIpad});

  final Map<String, Object?> cfBundleIcons;
  final Map<String, Object?>? cfBundleIconsIpad;

  /// Tab indented `<key>..</key><dict>..</dict>` pairs for the top level
  /// Info.plist dict, each line newline terminated.
  String toXmlFragment() {
    final out = StringBuffer();
    _writeEntry(out, 'CFBundleIcons', cfBundleIcons, 1);
    final ipad = cfBundleIconsIpad;
    if (ipad != null) _writeEntry(out, 'CFBundleIcons~ipad', ipad, 1);
    return out.toString();
  }

  static void _writeEntry(
    StringBuffer out,
    String key,
    Object? value,
    int depth,
  ) {
    final pad = '\t' * depth;
    out.writeln('$pad<key>$key</key>');
    _writeValue(out, value, depth);
  }

  static void _writeValue(StringBuffer out, Object? value, int depth) {
    final pad = '\t' * depth;
    if (value is Map) {
      out.writeln('$pad<dict>');
      for (final key in value.keys.map((k) => '$k').toList()..sort()) {
        _writeEntry(out, key, value[key], depth + 1);
      }
      out.writeln('$pad</dict>');
    } else if (value is List) {
      out.writeln('$pad<array>');
      for (final item in value) {
        _writeValue(out, item, depth + 1);
      }
      out.writeln('$pad</array>');
    } else {
      final text = '$value'
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;');
      out.writeln('$pad<string>$text</string>');
    }
  }

  /// Replaces any existing icon keys in [plistXml] with these.
  static String applyToInfoPlist(String plistXml, AppIconPlist icons) {
    var xml = PlistMutations.removePlistKey(plistXml, 'CFBundleIcons');
    xml = PlistMutations.removePlistKey(xml, 'CFBundleIcons~ipad');
    return PlistMutations.insertBeforeEnd(xml, icons.toXmlFragment());
  }
}

/// Writes loose app icon PNGs into an `.app` and describes them for
/// Info.plist exactly as `actool` does (measured against Xcode 26):
///
/// * Deployment target 11 or later: only `AppIcon60x60@2x.png` and
///   `AppIcon76x76@2x~ipad.png`, both always, whatever the target devices.
/// * Earlier targets: every slot loose (`AppIcon29x29.png`,
///   `AppIcon83.5x83.5@2x~ipad.png`, ...).
/// * Explicit slots are copied byte for byte; a single-size 1024 icon is
///   downscaled to RGBA PNGs with its alpha kept.
@internal
final class AppIconStager {
  AppIconStager(this.fileSystem, this.paths);

  final HostFileSystemInterface fileSystem;
  final p.Context paths;

  /// Slots `actool` writes loose for a deployment target of 11 or later.
  static const _modernPhone = [(60.0, 2)];
  static const _modernPad = [(76.0, 2)];

  /// Slots `actool` generates from a single-size icon below iOS 11.
  static const _legacySynthPhone = [
    (20.0, 2), (20.0, 3), (29.0, 2), (29.0, 3), //
    (40.0, 2), (40.0, 3), (60.0, 2), (60.0, 3),
  ];
  static const _legacySynthPad = [
    (20.0, 2),
    (29.0, 2),
    (40.0, 2),
    (76.0, 2),
    (83.5, 2),
  ];

  /// Stages [icons] (the primary icon) and [alternates] into [bundleDir].
  Future<AppIconPlist> stage(
    AppIconSetAsset icons, {
    required String bundleDir,
    required Set<AssetIdiom> deviceFamilies,
    String deploymentTarget = '13.0',
    List<AppIconSetAsset> alternates = const [],
  }) async {
    final wantPhone =
        deviceFamilies.contains(AssetIdiom.iphone) ||
        !deviceFamilies.contains(AssetIdiom.ipad);
    final wantPad = deviceFamilies.contains(AssetIdiom.ipad);
    final modern = _major(deploymentTarget) >= 11;

    final primary = _stageSet(icons, bundleDir, modern: modern);
    final hasPhone = primary.explicit ? primary.phoneSlots : wantPhone;
    final hasPad = primary.explicit ? primary.padSlots : wantPad;

    final alternateIcons = <String, Object?>{
      for (final alt in alternates)
        alt.name: modern
            ? {'CFBundleIconName': alt.name}
            : {
                'CFBundleIconFiles': _stageSet(
                  alt,
                  bundleDir,
                  modern: false,
                ).allBases,
                'CFBundleIconName': alt.name,
              },
    };

    Map<String, Object?> dict(
      List<String> files, {
      required bool named,
      required bool withAlternates,
    }) => {
      if (withAlternates && alternates.isNotEmpty)
        'CFBundleAlternateIcons': alternateIcons,
      'CFBundlePrimaryIcon': {
        'CFBundleIconFiles': files,
        if (named) 'CFBundleIconName': icons.name,
      },
    };

    return AppIconPlist(
      cfBundleIcons: dict(
        primary.phoneBases(marketingLast: !wantPhone),
        named: hasPhone,
        withAlternates: wantPhone,
      ),
      cfBundleIconsIpad: dict(
        primary.padBases,
        named: hasPad,
        withAlternates: wantPad,
      ),
    );
  }

  StagedIconSet _stageSet(
    AppIconSetAsset icons,
    String bundleDir, {
    required bool modern,
  }) {
    final name = icons.name;
    final staged = StagedIconSet(name);
    void put(String file, Uint8List? bytes, double size, {required bool pad}) {
      if (bytes == null || !staged.files.add(file)) return;
      final out = fileSystem.file(paths.join(bundleDir, file));
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(bytes);
      (pad ? staged.pad : staged.phone).add(size);
    }

    final usable = icons.images
        .where((e) => e.appearance == AssetAppearance.any)
        .toList();
    final slots = usable
        .where(
          (e) =>
              (e.idiom == AssetIdiom.iphone || e.idiom == AssetIdiom.ipad) &&
              e.platform == null,
        )
        .toList();
    staged
      ..phoneSlots = slots.any((e) => e.idiom == AssetIdiom.iphone)
      ..padSlots = slots.any((e) => e.idiom == AssetIdiom.ipad);

    if (slots.isNotEmpty) {
      staged.explicit = true;
      for (final e in slots) {
        final pad = e.idiom == AssetIdiom.ipad;
        if (modern &&
            !(pad ? _modernPad : _modernPhone).contains((e.size, e.scale))) {
          continue;
        }
        put(
          _fileName(name, e.size, e.scale, pad),
          _asPng(fileSystem.file(e.filePath).readAsBytesSync()),
          e.size,
          pad: pad,
        );
      }
      return staged;
    }

    final source =
        (usable
                .where(
                  (e) =>
                      e.idiom == AssetIdiom.universal ||
                      e.idiom == AssetIdiom.iosMarketing,
                )
                .toList()
              ..sort((a, b) => b.pixelSize.compareTo(a.pixelSize)))
            .firstOrNull;
    if (source == null) return staged;
    final bytes = fileSystem.file(source.filePath).readAsBytesSync();
    final decoded = _decode(bytes);
    if (decoded == null) return staged;
    if (!modern) {
      staged.marketing = true;
      put(
        _fileName(name, source.size, 1, false),
        _asPng(bytes),
        -1,
        pad: false,
      );
      staged.phone.remove(-1);
    }
    for (final (size, scale) in modern ? _modernPhone : _legacySynthPhone) {
      put(
        _fileName(name, size, scale, false),
        _resized(decoded, size, scale),
        size,
        pad: false,
      );
    }
    for (final (size, scale) in modern ? _modernPad : _legacySynthPad) {
      put(
        _fileName(name, size, scale, true),
        _resized(decoded, size, scale),
        size,
        pad: true,
      );
    }
    staged.marketingSize = source.size;
    return staged;
  }

  static int _major(String version) =>
      int.tryParse(version.trim().split('.').first) ?? 13;

  static String _fmt(double size) =>
      size == size.roundToDouble() ? '${size.round()}' : '$size';

  static String _fileName(String name, double size, int scale, bool pad) {
    final s = _fmt(size);
    final at = scale == 1 ? '' : '@${scale}x';
    return '$name${s}x$s$at${pad ? '~ipad' : ''}.png';
  }

  /// Downscaled RGBA PNG, alpha kept (actool does not flatten).
  static Uint8List _resized(img.Image source, double size, int scale) {
    final px = (size * scale).round();
    final out = img.copyResize(
      source.numChannels == 4 ? source : source.convert(numChannels: 4),
      width: px,
      height: px,
      interpolation: img.Interpolation.cubic,
    );
    return Uint8List.fromList(img.encodePng(out));
  }

  static img.Image? _decode(Uint8List bytes) {
    try {
      return img.decodeImage(bytes);
    } on Object {
      return null;
    }
  }

  /// PNG bytes unchanged, other formats re-encoded; null if undecodable.
  static Uint8List? _asPng(Uint8List bytes) {
    const sig = [0x89, 0x50, 0x4E, 0x47];
    if (bytes.length > 4 &&
        [for (var i = 0; i < 4; i++) bytes[i]].toString() == sig.toString()) {
      return bytes;
    }
    final decoded = _decode(bytes);
    return decoded == null ? null : Uint8List.fromList(img.encodePng(decoded));
  }
}

/// Loose files one icon set produced, by family.
@internal
final class StagedIconSet {
  StagedIconSet(this.name);

  final String name;
  final files = <String>{};
  final phone = <double>{};
  final pad = <double>{};
  bool explicit = false;
  bool phoneSlots = false;
  bool padSlots = false;

  /// A single-size source copied loose as `AppIcon1024x1024.png` (< iOS 11).
  bool marketing = false;
  double marketingSize = 1024;

  String _base(double size) {
    final s = AppIconStager._fmt(size);
    return '$name${s}x$s';
  }

  List<String> _sorted(Iterable<double> sizes) =>
      (sizes.toSet().toList()..sort()).map(_base).toList();

  String get _marketingBase => _base(marketingSize);

  List<String> phoneBases({bool marketingLast = false}) => [
    if (marketing && !marketingLast) _marketingBase,
    ..._sorted(phone),
    if (marketing && marketingLast) _marketingBase,
  ];

  /// iPad list: includes the iPhone sizes, except for the full set actool
  /// generates from a single-size icon below iOS 11.
  List<String> get padBases => [
    if (marketing) _marketingBase,
    ..._sorted(explicit || !marketing ? {...phone, ...pad} : pad),
  ];

  List<String> get allBases => [
    if (marketing) _marketingBase,
    ..._sorted({...phone, ...pad}),
  ];
}
