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
/// Info.plist, matching `actool`'s naming (`AppIcon60x60@2x.png`,
/// `AppIcon76x76@2x~ipad.png`).
@internal
final class AppIconStager {
  AppIconStager(this.fileSystem, this.paths);

  final HostFileSystemInterface fileSystem;
  final p.Context paths;

  /// (point size, scale) pairs synthesized from a single 1024 source.
  static const _phoneSynth = [(60.0, 2), (60.0, 3)];
  static const _padSynth = [(76.0, 2), (83.5, 2)];

  /// Returns null `cfBundleIconsIpad` unless [deviceFamilies] has ipad.
  Future<AppIconPlist> stage(
    AppIconSetAsset icons, {
    required String bundleDir,
    required Set<AssetIdiom> deviceFamilies,
  }) async {
    final wantPhone =
        deviceFamilies.contains(AssetIdiom.iphone) ||
        !deviceFamilies.contains(AssetIdiom.ipad);
    final wantPad = deviceFamilies.contains(AssetIdiom.ipad);
    final name = icons.name;

    // base name (e.g. AppIcon60x60) -> size, per family.
    final phoneBases = <String, double>{};
    final padBases = <String, double>{};
    final written = <String>{};

    Future<void> put(
      String file,
      Uint8List bytes,
      Map<String, double> bases,
      double size,
    ) async {
      if (!written.add(file)) return;
      final out = fileSystem.file(paths.join(bundleDir, file));
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(bytes);
      bases['$name${_fmt(size)}x${_fmt(size)}'] = size;
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

    for (final e in slots) {
      final isPad = e.idiom == AssetIdiom.ipad;
      if (isPad ? !wantPad : !wantPhone) continue;
      final bytes = _asPng(fileSystem.file(e.filePath).readAsBytesSync());
      if (bytes == null) continue;
      await put(
        _fileName(name, e.size, e.scale, isPad),
        bytes,
        isPad ? padBases : phoneBases,
        e.size,
      );
    }

    // Single-size / marketing source: synthesize what the loose slots lack.
    final sources =
        usable
            .where(
              (e) => e.idiom != AssetIdiom.iphone && e.idiom != AssetIdiom.ipad,
            )
            .where(
              (e) =>
                  e.idiom == AssetIdiom.universal ||
                  e.idiom == AssetIdiom.iosMarketing,
            )
            .toList()
          ..sort((a, b) => b.pixelSize.compareTo(a.pixelSize));
    if (sources.isNotEmpty &&
        (phoneBases.isEmpty || (wantPad && padBases.isEmpty))) {
      final decoded = _decode(
        fileSystem.file(sources.first.filePath).readAsBytesSync(),
      );
      if (decoded != null) {
        final opaque = _flatten(decoded);
        if (wantPhone && phoneBases.isEmpty) {
          for (final (size, scale) in _phoneSynth) {
            await put(
              _fileName(name, size, scale, false),
              _resized(opaque, size, scale),
              phoneBases,
              size,
            );
          }
        }
        if (wantPad && padBases.isEmpty) {
          for (final (size, scale) in _padSynth) {
            await put(
              _fileName(name, size, scale, true),
              _resized(opaque, size, scale),
              padBases,
              size,
            );
          }
        }
      }
    }

    List<String> ordered(Map<String, double> m) =>
        (m.entries.toList()..sort((a, b) => a.value.compareTo(b.value)))
            .map((e) => e.key)
            .toList();

    Map<String, Object?> dict(List<String> files) => {
      'CFBundlePrimaryIcon': {
        'CFBundleIconFiles': files,
        'CFBundleIconName': name,
      },
    };

    final phone = ordered(phoneBases);
    return AppIconPlist(
      cfBundleIcons: dict(phone),
      cfBundleIconsIpad: wantPad
          ? dict(ordered({...phoneBases, ...padBases}))
          : null,
    );
  }

  static String _fmt(double size) =>
      size == size.roundToDouble() ? '${size.round()}' : '$size';

  static String _fileName(String name, double size, int scale, bool pad) {
    final s = _fmt(size);
    final at = scale == 1 ? '' : '@${scale}x';
    return '$name${s}x$s$at${pad ? '~ipad' : ''}.png';
  }

  static Uint8List _resized(img.Image source, double size, int scale) {
    final px = (size * scale).round();
    final out = img.copyResize(
      source,
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

  /// iOS icons must be opaque: composite onto white.
  static img.Image _flatten(img.Image source) {
    if (!source.hasAlpha) return source;
    final base = img.Image(width: source.width, height: source.height)
      ..clear(img.ColorRgb8(255, 255, 255));
    return img.compositeImage(base, source);
  }
}
