import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:standard_message_codec/standard_message_codec.dart';
import 'package:xcross/src/shared/flutter/build/icon_tree_shaker.dart';
import 'package:xcross/src/shared/flutter/build/impeller_shader_compiler.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/models/pubspec_info.dart';
import 'package:xcross/src/shared/flutter/project/pubspec_info_reader.dart';
import 'package:xcross/src/shared/packages/package_config_resolver.dart';

@internal
final class FlutterAssetsCompiler {
  FlutterAssetsCompiler({
    required this.fileSystem,
    required this.paths,
    required this.projectRoot,
    required this.flutterRoot,
    this.flavor,
  }) : packageConfigs = PackageConfigResolver(
         fileSystem: fileSystem,
         paths: paths,
       );
  final PackageConfigResolver packageConfigs;
  final HostFileSystemInterface fileSystem;
  final p.Context paths;
  final String projectRoot;
  final String flutterRoot;

  /// `--flavor`, which selects flavored `shaders:` entries.
  final String? flavor;

  /// Fragment programs Flutter bundles for every app, as asset key to the
  /// framework source, mirroring flutter_tools' `_getFrameworkShaders`.
  @visibleForTesting
  Map<String, String> frameworkShaders() {
    final library = paths.join(
      flutterRoot,
      'packages',
      'flutter',
      'lib',
      'src',
    );
    final candidates = {
      'shaders/ink_sparkle.frag': [
        paths.join(library, 'material', 'shaders', 'ink_sparkle.frag'),
      ],
      'shaders/stretch_effect.frag': [
        paths.join(library, 'widgets', 'shaders', 'stretch_effect.frag'),
        paths.join(library, 'material', 'shaders', 'stretch_effect.frag'),
      ],
    };
    return {
      for (final MapEntry(:key, :value) in candidates.entries)
        if (value.where((path) => fileSystem.file(path).existsSync())
            case final sources when sources.isNotEmpty)
          key: sources.first,
    };
  }

  Future<void> bundle<T extends PlatformHostInterface>({
    required String assetsDir,
    required String appDill,
    required String vmSnapshotData,
    required String isolateSnapshotData,
    required PubspecInfo pubspec,
    required ImpellerShaderCompiler<T> shaders,
    IconTreeShaker<T>? icons,
  }) async {
    await _copyDataAssets(
      assetsDir,
      vmSnapshotData,
      isolateSnapshotData,
      appDill,
    );
    final manifest = await copyPubspecAssets(assetsDir, pubspec);
    final fonts = await copyFonts(assetsDir, pubspec);
    await compileShaders(assetsDir, pubspec, shaders, manifest);
    await icons?.shake(
      assetsDir: assetsDir,
      appDill: appDill,
      fontManifest: fonts,
    );
    writeManifests(assetsDir, manifest, fonts);
  }

  /// Compile the framework shaders and every `shaders:` entry of the app and
  /// its dependencies. Declared shaders join [manifest], as in flutter_tools.
  @visibleForTesting
  Future<void> compileShaders<T extends PlatformHostInterface>(
    String assetsDir,
    PubspecInfo pubspec,
    ImpellerShaderCompiler<T> compiler,
    Map<String, List<String>> manifest,
  ) async {
    final sources = <String, String>{};
    Future<void> declare(String shader, String root, String? package) async {
      final (:key, :source) = await _resolveEntry(shader, root, package);
      if (!fileSystem.file(source).existsSync()) {
        throw FlutterBuildError(
          '${package ?? '.'}/pubspec.yaml: shader not found: $key',
        );
      }
      sources[key] = source;
      manifest[key] = [key];
    }

    for (final shader in _selected(pubspec, 'pubspec.yaml')) {
      _rejectShaderAsset(pubspec, shader, 'pubspec.yaml');
      await declare(shader, projectRoot, null);
    }
    for (final (:name, :root, :info) in await _dependencyPubspecs(pubspec)) {
      for (final shader in _selected(info, '$name/pubspec.yaml')) {
        _rejectShaderAsset(info, shader, '$name/pubspec.yaml');
        await declare(shader, root, name);
      }
    }
    for (final MapEntry(:key, :value) in frameworkShaders().entries) {
      sources.putIfAbsent(key, () => value);
    }
    for (final MapEntry(:key, :value) in sources.entries) {
      await compiler.compile(
        source: value,
        output: paths.joinAll([assetsDir, ...p.url.split(key)]),
      );
    }
  }

  Iterable<String> _selected(PubspecInfo pubspec, String owner) sync* {
    for (final shader in pubspec.shaders) {
      if (!shader.appliesTo(flavor: flavor, platform: 'ios')) continue;
      if (shader.hasTransformers) {
        throw FlutterBuildError(
          '$owner: shader "${shader.path}" declares transformers, which xcross '
          'does not run yet.',
        );
      }
      yield shader.path;
    }
  }

  static void _rejectShaderAsset(
    PubspecInfo pubspec,
    String shader,
    String owner,
  ) {
    for (final asset in pubspec.assets) {
      if (asset == shader) {
        throw FlutterBuildError(
          '$owner: shader "$shader" is also defined as an asset. Shaders '
          'should only be defined in the "shaders" section of the '
          'pubspec.yaml, not in the "assets" section.',
        );
      }
      if (asset.endsWith('/') && shader.startsWith(asset)) {
        throw FlutterBuildError(
          '$owner: shader "$shader" is included in the asset directory '
          '"$asset". Shaders should only be defined in the "shaders" section '
          'of the pubspec.yaml, not in the "assets" section.',
        );
      }
    }
  }

  /// Resolve a pubspec path [entry] declared by [package] (`null` for the
  /// app) rooted at [root] into its bundle key and source file.
  ///
  /// Mirrors flutter_tools' `_resolvePackageAsset`: an entry spelled
  /// `packages/<pkg>/<path>` that is not a file under [root] names `<path>`
  /// inside `<pkg>`'s `lib/` directory and keeps its key verbatim (e.g.
  /// material_ui's `packages/material_ui/shaders/ink_sparkle.frag`).
  Future<({String key, String source})> _resolveEntry(
    String entry,
    String root,
    String? package,
  ) async {
    final segments = p.url.split(entry);
    final local = paths.joinAll([root, ...segments]);
    if (segments.length > 2 &&
        segments.first == 'packages' &&
        !fileSystem.file(local).existsSync()) {
      final config = await _packageConfig();
      final target = config[segments[1]]?.packageUriRoot;
      if (target != null && target.scheme == 'file') {
        return (
          key: entry,
          source: paths.joinAll([paths.fromUri(target), ...segments.skip(2)]),
        );
      }
    }
    return (
      key: package == null ? entry : p.url.join('packages', package, entry),
      source: local,
    );
  }

  PackageConfig? _cachedPackageConfig;

  Future<PackageConfig> _packageConfig() async =>
      _cachedPackageConfig ??= await loadPackageConfig(
        fileSystem.file(await packageConfigs.require(projectRoot)),
      );

  Future<void> _copyDataAssets(
    String assetsDir,
    String vmSnapshotData,
    String isolateSnapshotData,
    String appDill,
  ) async {
    // kernel_blob.bin — Dart kernel for JIT execution.
    await fileSystem
        .file(appDill)
        .copy(paths.join(assetsDir, 'kernel_blob.bin'));
    // Snapshot data files (name remap: .bin suffix dropped, stem changed).
    await fileSystem
        .file(vmSnapshotData)
        .copy(paths.join(assetsDir, 'vm_snapshot_data'));
    await fileSystem
        .file(isolateSnapshotData)
        .copy(paths.join(assetsDir, 'isolate_snapshot_data'));
  }

  /// Copy `flutter: assets:` entries into `flutter_assets/`, preserving their
  /// pubspec-relative paths, and build the `AssetManifest` key → variants map.
  ///
  /// ponytail: no density-variant grouping (2x/3x sibling dirs) — every asset
  /// resolves to exactly its declared path. Add `_AssetDirectoryCache`-style
  /// variant scanning (see flutter_tools' asset.dart) if that's ever needed.
  Future<Map<String, List<String>>> copyPubspecAssets(
    String assetsDir,
    PubspecInfo pubspec,
  ) async {
    final manifest = <String, List<String>>{};
    for (final entry in pubspec.assets) {
      if (entry.endsWith('/')) {
        final dir = fileSystem.directory(paths.join(projectRoot, entry));
        if (!dir.existsSync()) {
          throw FlutterBuildError(
            'pubspec.yaml: asset directory not found: $entry',
          );
        }
        // Non-recursive, matching flutter_tools' folder-entry semantics.
        for (final file in dir.listSync().whereType<File>()) {
          final key = '$entry${paths.basename(file.path)}';
          await _copyAssetFile(file.path, assetsDir, key);
          manifest[key] = [key];
        }
      } else {
        final src = paths.join(projectRoot, entry);
        final srcExists = fileSystem.file(src).existsSync();
        if (!srcExists) {
          throw FlutterBuildError('pubspec.yaml: asset not found: $entry');
        }
        await _copyAssetFile(src, assetsDir, entry);
        manifest[entry] = [entry];
      }
    }
    return manifest;
  }

  /// Copy `MaterialIcons-Regular.otf` (if material design is used) and any
  /// `flutter: fonts:` families, returning `FontManifest.json` descriptors.
  @visibleForTesting
  Future<List<Map<String, Object?>>> copyFonts(
    String assetsDir,
    PubspecInfo pubspec,
  ) async {
    final fonts = <Map<String, Object?>>[];
    if (pubspec.usesMaterialDesign) {
      await _copyMaterialIcons(assetsDir, fonts);
    }
    await _copyPubspecFonts(assetsDir, pubspec, fonts);
    await _copyDependencyFonts(assetsDir, pubspec, fonts);
    return fonts;
  }

  Future<void> _copyMaterialIcons(
    String assetsDir,
    List<Map<String, Object?>> fonts,
  ) async {
    final src = paths.join(
      flutterRoot,
      'bin',
      'cache',
      'artifacts',
      'material_fonts',
      'MaterialIcons-Regular.otf',
    );
    final srcExists = fileSystem.file(src).existsSync();
    if (srcExists) {
      await _copyAssetFile(src, assetsDir, 'fonts/MaterialIcons-Regular.otf');
      fonts.add(const {
        'family': 'MaterialIcons',
        'fonts': [
          {'asset': 'fonts/MaterialIcons-Regular.otf'},
        ],
      });
    }
  }

  Future<void> _copyPubspecFonts(
    String assetsDir,
    PubspecInfo pubspec,
    List<Map<String, Object?>> fonts,
  ) async {
    for (final family in pubspec.fonts) {
      for (final font in family.fonts) {
        final (:key, source: src) = await _resolveEntry(
          font.asset,
          projectRoot,
          null,
        );
        final srcExists = fileSystem.file(src).existsSync();
        if (!srcExists) {
          throw FlutterBuildError(
            'pubspec.yaml: font asset not found: ${font.asset}',
          );
        }
        await _copyAssetFile(src, assetsDir, key);
      }
      fonts.add(family.descriptor);
    }
  }

  Future<void> _copyDependencyFonts(
    String assetsDir,
    PubspecInfo pubspec,
    List<Map<String, Object?>> fonts,
  ) async {
    for (final (:name, :root, :info) in await _dependencyPubspecs(pubspec)) {
      await _copyPackageFonts(assetsDir, name, root, info, fonts);
    }
  }

  /// Local dependencies with a `pubspec.yaml`, in [pubspec]'s order.
  Future<List<({String name, String root, PubspecInfo info})>>
  _dependencyPubspecs(PubspecInfo pubspec) async {
    final packageConfig = await _packageConfig();
    final reader = PubspecInfoReader(fileSystem, paths);
    return [
      for (final packageName in pubspec.dependencies)
        if (packageConfig[packageName] case final package?
            when package.root.scheme == 'file')
          if (paths.fromUri(package.root) case final packageRoot
              when fileSystem
                  .file(paths.join(packageRoot, 'pubspec.yaml'))
                  .existsSync())
            (
              name: packageName,
              root: packageRoot,
              info: reader.loadSync(packageRoot),
            ),
    ];
  }

  Future<void> _copyPackageFonts(
    String assetsDir,
    String packageName,
    String packageRoot,
    PubspecInfo packageInfo,
    List<Map<String, Object?>> fonts,
  ) async {
    for (final family in packageInfo.fonts) {
      final descriptors = <Map<String, Object>>[];
      for (final font in family.fonts) {
        final (:key, source: src) = await _resolveEntry(
          font.asset,
          packageRoot,
          packageName,
        );
        final srcExists = fileSystem.file(src).existsSync();
        if (!srcExists) {
          throw FlutterBuildError(
            '$packageName/pubspec.yaml: font asset not found: ${font.asset}',
          );
        }
        await _copyAssetFile(src, assetsDir, key);
        descriptors.add({...font.descriptor, 'asset': key});
      }
      fonts.add({
        'family': 'packages/$packageName/${family.family}',
        'fonts': descriptors,
      });
    }
  }

  /// Copy [src] to `assetsDir/key`, creating parent directories as needed.
  Future<void> _copyAssetFile(String src, String assetsDir, String key) async {
    final dst = paths.join(assetsDir, key);
    await fileSystem.directory(paths.dirname(dst)).create(recursive: true);
    await fileSystem.file(src).copy(dst);
  }

  void writeManifests(
    String assetsDir,
    Map<String, List<String>> assetManifest,
    List<Map<String, Object?>> fonts,
  ) {
    // AssetManifest.bin — the exact binary shape flutter_tools produces:
    // Map<String, List<{"asset": path}>>, StandardMessageCodec-encoded.
    final binMessage = <String, Object?>{
      for (final entry in assetManifest.entries)
        entry.key: [
          for (final variant in entry.value) {'asset': variant},
        ],
    };
    final binBytes = const StandardMessageCodec().encodeMessage(binMessage);
    fileSystem
        .file(paths.join(assetsDir, 'AssetManifest.bin'))
        .writeAsBytesSync(
          binBytes?.buffer.asUint8List(0, binBytes.lengthInBytes) ??
              Uint8List(0),
        );

    // AssetManifest.json — legacy JSON variant still read by some plugins.
    fileSystem
        .file(paths.join(assetsDir, 'AssetManifest.json'))
        .writeAsStringSync(jsonEncode(assetManifest));

    // FontManifest.json — registers custom + Material fonts with the engine.
    fileSystem
        .file(paths.join(assetsDir, 'FontManifest.json'))
        .writeAsStringSync(jsonEncode(fonts));
  }
}
