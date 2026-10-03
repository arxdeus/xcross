import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:meta/meta.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:standard_message_codec/standard_message_codec.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/flutter/models/pubspec_info.dart';
import 'package:xcross/src/package_config_resolver.dart';
import 'package:xcross/src/shared/flutter/project/pubspec_info_reader.dart';

final class FlutterAssetsCompiler {
  FlutterAssetsCompiler({
    required this.fileSystem,
    required this.projectRoot,
    required this.flutterRoot,
  });
  final HostFileSystemInterface fileSystem;
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
    await fileSystem.file(appDill).copy(p.join(assetsDir, 'kernel_blob.bin'));
    // Snapshot data files (name remap: .bin suffix dropped, stem changed).
    await fileSystem
        .file(vmSnapshotData)
        .copy(p.join(assetsDir, 'vm_snapshot_data'));
    await fileSystem
        .file(isolateSnapshotData)
        .copy(p.join(assetsDir, 'isolate_snapshot_data'));
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
        final dir = fileSystem.directory(p.join(projectRoot, entry));
        if (!dir.existsSync()) {
          throw FlutterBuildError(
            'pubspec.yaml: asset directory not found: $entry',
          );
        }
        // Non-recursive, matching flutter_tools' folder-entry semantics.
        for (final file in dir.listSync().whereType<File>()) {
          final key = '$entry${p.basename(file.path)}';
          await _copyAssetFile(file.path, assetsDir, key);
          manifest[key] = [key];
        }
      } else {
        final src = p.join(projectRoot, entry);
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
      final src = p.join(
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

    for (final family in pubspec.fonts) {
      for (final font in family.fonts) {
        final src = p.join(projectRoot, font.asset);
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

    final packageConfigPath = await PackageConfigResolver.require(projectRoot);
    final packageConfig = await loadPackageConfig(
      fileSystem.file(packageConfigPath),
    );
    for (final packageName in pubspec.dependencies) {
      final package = packageConfig[packageName];
      if (package == null || package.root.scheme != 'file') continue;
      final packageRoot = package.root.toFilePath();
      final packagePubspec = fileSystem.file(
        p.join(packageRoot, 'pubspec.yaml'),
      );
      if (!packagePubspec.existsSync()) continue;

      final packageInfo = PubspecInfoReader(
        fileSystem,
        p.context,
      ).loadSync(packageRoot);
      for (final family in packageInfo.fonts) {
        final descriptors = <Map<String, Object>>[];
        for (final font in family.fonts) {
          final key = p.url.join('packages', packageName, font.asset);
          final src = p.join(packageRoot, font.asset);
          if (!fileSystem.file(src).existsSync()) {
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

    return fonts;
  }

  /// Copy [src] to `assetsDir/key`, creating parent directories as needed.
  Future<void> _copyAssetFile(String src, String assetsDir, String key) async {
    final dst = p.join(assetsDir, key);
    await fileSystem.directory(p.dirname(dst)).create(recursive: true);
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
        .file(p.join(assetsDir, 'AssetManifest.bin'))
        .writeAsBytesSync(
          binBytes?.buffer.asUint8List(0, binBytes.lengthInBytes) ??
              Uint8List(0),
        );

    // AssetManifest.json — legacy JSON variant still read by some plugins.
    fileSystem
        .file(p.join(assetsDir, 'AssetManifest.json'))
        .writeAsStringSync(jsonEncode(assetManifest));

    // FontManifest.json — registers custom + Material fonts with the engine.
    fileSystem
        .file(p.join(assetsDir, 'FontManifest.json'))
        .writeAsStringSync(jsonEncode(fonts));
  }
}
