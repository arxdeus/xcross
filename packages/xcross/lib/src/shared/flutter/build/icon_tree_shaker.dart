import 'dart:convert';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/errors.dart';

/// Subsets icon fonts to the glyphs the app references, like flutter_tools'
/// `IconTreeShaker`: `const_finder` lists the constant `IconData` instances in
/// the kernel, and `font-subset` keeps only their code points.
@internal
final class IconTreeShaker<T extends PlatformHostInterface> {
  IconTreeShaker({
    required this.runner,
    required this.dart,
    required this.constFinder,
    required this.fontSubset,
  });
  final ProcessRunner<T> runner;
  final String dart;
  final String constFinder;
  final String fontSubset;

  static const _iconDataLibrary = 'package:flutter/src/widgets/icon_data.dart';

  /// Subset every icon font in [fontManifest] that [appDill] references, in
  /// place under [assetsDir].
  Future<void> shake({
    required String assetsDir,
    required String appDill,
    required List<Map<String, Object?>> fontManifest,
  }) async {
    final iconData = await findConstants(appDill);
    final fonts = iconFonts(fontManifest, iconData.keys.toSet());
    if (fonts.length != iconData.length) {
      runner.log.logStatus(
        'Expected to find fonts for ${iconData.keys}, but found '
        '${fonts.keys}. This usually means you are referring to font families '
        'in an IconData class but not including them in the assets section of '
        'your pubspec.yaml, are missing the package that would include them, '
        'or are missing "uses-material-design: true".',
      );
    }
    final paths = runner.host.paths.context;
    for (final MapEntry(key: family, value: asset) in fonts.entries) {
      final codePoints = iconData[family];
      if (codePoints == null) {
        throw FlutterBuildError(
          'Expected to find font code points for $family, but none were found.',
        );
      }
      await subset(paths.join(assetsDir, asset), codePoints);
    }
  }

  /// Family key (`Family` or `packages/<package>/Family`) to the code points
  /// of every constant `IconData` in [appDill].
  @visibleForTesting
  Future<Map<String, List<int>>> findConstants(String appDill) async {
    final result = await runner.run(dart, [
      constFinder,
      '--kernel-file',
      appDill,
      '--class-library-uri',
      _iconDataLibrary,
      '--class-name',
      'IconData',
      '--annotation-class-name',
      '_StaticIconProvider',
      '--annotation-class-library-uri',
      _iconDataLibrary,
    ]);
    if (result.exitCode != 0) {
      throw FlutterBuildError('ConstFinder failure: ${result.stderr}');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(result.stdout);
    } on FormatException catch (error) {
      throw FlutterBuildError('Invalid ConstFinder output: $error');
    }
    if (decoded is! Map<String, Object?>) {
      throw FlutterBuildError(
        'Invalid ConstFinder output: expected a top level JSON object, got '
        '$decoded.',
      );
    }
    final nonConstant = _objects(decoded['nonConstantLocations']);
    if (nonConstant.isNotEmpty) {
      throw FlutterBuildError(
        'This application cannot tree shake icons fonts. It has non-constant '
        'instances of IconData at the following locations:\n'
        '${nonConstant.map((l) => '- ${l['file']}:${l['line']}:${l['column']}').join('\n')}\n'
        'Avoid non-constant invocations of IconData or try to build again with '
        '--no-tree-shake-icons.',
      );
    }
    final constants = <String, List<int>>{};
    for (final instance in _objects(decoded['constantInstances'])) {
      final package = instance['fontPackage'];
      final family = instance['fontFamily'];
      final codePoint = instance['codePoint'];
      if (package is! String? || family is! String? || codePoint is! num) {
        throw FlutterBuildError(
          'Invalid ConstFinder result. Expected "fontPackage" to be a String, '
          '"fontFamily" to be a String, and "codePoint" to be an int, got: '
          '$instance.',
        );
      }
      if (family == null) continue;
      final key = package == null ? family : 'packages/$package/$family';
      (constants[key] ??= []).add(codePoint.round());
    }
    return constants;
  }

  /// Family key to the asset key of its only font file, for [families].
  @visibleForTesting
  static Map<String, String> iconFonts(
    List<Map<String, Object?>> fontManifest,
    Set<String> families,
  ) {
    final result = <String, String>{};
    for (final entry in fontManifest) {
      final family = entry['family'];
      if (family is! String) {
        throw FlutterBuildError(
          'FontManifest.json invalid: expected the family value to be a '
          'string, got: $family.',
        );
      }
      if (!families.contains(family)) continue;
      final fonts = _objects(entry['fonts']);
      if (fonts.length != 1) {
        throw FlutterBuildError(
          'This tool cannot process icon fonts with multiple fonts in a single '
          'family.',
        );
      }
      final asset = fonts.single['asset'];
      if (asset is! String) {
        throw FlutterBuildError(
          'FontManifest.json invalid: expected "asset" value to be a string, '
          'got: $asset.',
        );
      }
      result[family] = asset;
    }
    return result;
  }

  /// Replace [font] with a subset holding only [codePoints]. Files that are
  /// not TrueType/OpenType fonts are left untouched, as flutter_tools does.
  @visibleForTesting
  Future<bool> subset(String font, List<int> codePoints) async {
    final fileSystem = runner.host.fileSystem;
    final paths = runner.host.paths.context;
    final input = fileSystem.file(font);
    if (!isTrueTypeFont(paths.basename(font), _header(font))) return false;
    final output = '$font.subset';
    final process = await runner.start(fontSubset, [output, font]);
    final stdoutText = process.stdout.transform(utf8.decoder).join();
    final stderrText = process.stderr.transform(utf8.decoder).join();
    try {
      process.stdin.writeln(codePoints.join(' '));
      await process.stdin.flush();
      await process.stdin.close();
    } on Object {
      // The exit code reports the failure.
    }
    final code = await process.exitCode;
    final stdout = await stdoutText;
    final stderr = await stderrText;
    if (code != 0) {
      runner.log.logTrace(stdout);
      throw FlutterBuildError(
        'Font subsetting failed with exit code $code.\n$stderr',
      );
    }
    final before = input.lengthSync();
    await fileSystem.file(output).rename(font);
    final after = fileSystem.file(font).lengthSync();
    final reduction = ((before - after) / before * 100).toStringAsFixed(1);
    runner.log.logStatus(
      'Font asset "${paths.basename(font)}" was tree-shaken, reducing it from '
      '$before to $after bytes ($reduction% reduction). Tree-shaking can be '
      'disabled by providing the --no-tree-shake-icons flag when building your '
      'app.',
    );
    return true;
  }

  List<int> _header(String font) {
    final file = runner.host.fileSystem.file(font);
    if (!file.existsSync() || file.lengthSync() < 12) return const [];
    final handle = file.openSync();
    try {
      return handle.readSync(12);
    } finally {
      handle.closeSync();
    }
  }

  /// flutter_tools accepts `font/ttf` and `font/otf` (package:mime: by
  /// extension, unless the header is a WOFF2 file) of at least 12 bytes.
  @visibleForTesting
  static bool isTrueTypeFont(String name, List<int> header) {
    if (header.length < 12) return false;
    if (ascii.decode(header.sublist(0, 4), allowInvalid: true) == 'wOF2') {
      return false;
    }
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return const {'ttf', 'otf'}.contains(name.substring(dot + 1).toLowerCase());
  }

  static List<Map<String, Object?>> _objects(Object? value) => [
    if (value is List<Object?>)
      for (final item in value)
        if (item is Map<String, Object?>) item,
  ];
}
