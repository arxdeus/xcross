import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:standard_message_codec/standard_message_codec.dart';
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
  }) : packageConfigs = PackageConfigResolver(
         fileSystem: fileSystem,
         paths: paths,
       );
  final PackageConfigResolver packageConfigs;
  final HostFileSystemInterface fileSystem;
  final p.Context paths;
  final String projectRoot;
  final String flutterRoot;
  Future<void> bundle({
    required String assetsDir,
    required String appDill,
    required String vmSnapshotData,
    required String isolateSnapshotData,
    required PubspecInfo pubspec,
  }) async {
    await _copyDataAssets(
      assetsDir,
      vmSnapshotData,
      isolateSnapshotData,
      appDill,
    );
    final manifest = await copyPubspecAssets(assetsDir, pubspec);
    final fonts = await copyFonts(assetsDir, pubspec);
    writeManifests(assetsDir, manifest, fonts);
  }

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
        final src = paths.join(projectRoot, font.asset);
        final srcExists = fileSystem.file(src).existsSync();
        if (!srcExists) {
          throw FlutterBuildError(
            'pubspec.yaml: font asset not found: ${font.asset}',
          );
        }
        await _copyAssetFile(src, assetsDir, font.asset);
      }
      fonts.add(family.descriptor);
    }
  }

  Future<void> _copyDependencyFonts(
    String assetsDir,
    PubspecInfo pubspec,
    List<Map<String, Object?>> fonts,
  ) async {
    final packageConfigPath = await packageConfigs.require(projectRoot);
    final packageConfig = await loadPackageConfig(
      fileSystem.file(packageConfigPath),
    );
    for (final packageName in pubspec.dependencies) {
      final package = packageConfig[packageName];
      final isLocalPackage = package != null && package.root.scheme == 'file';
      if (!isLocalPackage) continue;
      final packageRoot = paths.fromUri(package.root);
      final packagePubspec = fileSystem.file(
        paths.join(packageRoot, 'pubspec.yaml'),
      );
      if (!packagePubspec.existsSync()) continue;
      await _copyPackageFonts(assetsDir, packageName, packageRoot, fonts);
    }
  }

  Future<void> _copyPackageFonts(
    String assetsDir,
    String packageName,
    String packageRoot,
    List<Map<String, Object?>> fonts,
  ) async {
    final packageInfo = PubspecInfoReader(
      fileSystem,
      paths,
    ).loadSync(packageRoot);
    for (final family in packageInfo.fonts) {
      final descriptors = <Map<String, Object>>[];
      for (final font in family.fonts) {
        final key = p.url.join('packages', packageName, font.asset);
        final src = paths.join(packageRoot, font.asset);
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
