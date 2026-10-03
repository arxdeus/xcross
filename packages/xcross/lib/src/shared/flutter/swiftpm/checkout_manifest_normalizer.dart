import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';

abstract interface class SwiftPmVendoredManifestPolicy {
  Future<String> normalize(
    String manifest, {
    required String packageDir,
    required Set<String> consumedProducts,
    Map<String, List<String>>? fallbackSwiftModules,
  });
}

final class SwiftPmCheckoutManifestNormalizer<T extends PlatformHostInterface> {
  const SwiftPmCheckoutManifestNormalizer({
    required this.fileSystem,
    required this.filesystem,
    required this.attributes,
    required this.policy,
  });
  final SwiftPmArtifactFileSystem fileSystem;
  final SwiftPmFilesystem<T> filesystem;
  final SwiftPmCheckoutAttributes attributes;
  final SwiftPmVendoredManifestPolicy policy;
  Future<bool> normalizeVendoredPackageManifests(
    String packageDir, {
    required Set<String> consumedProducts,
    Map<String, List<String>>? fallbackSwiftModules,
    Future<String> Function(String manifest)? rewriteDependencies,
  }) async {
    var changed = false;
    final manifests = <File>[];
    await for (final entity
        in fileSystem.directory(packageDir).list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name != 'Package.swift' &&
          !(name.startsWith('Package@') && name.endsWith('.swift'))) {
        continue;
      }
      manifests.add(entity);
    }
    Future<void> update(File manifest, String original, String updated) async {
      if (updated == original) return;
      await attributes.clear(manifest.path);
      await manifest.writeAsString(updated);
      await filesystem.stampByContent(manifest.path, updated);
      changed = true;
    }

    for (final manifest in manifests) {
      final original = await manifest.readAsString();
      final normalized = await policy.normalize(
        original,
        packageDir: packageDir,
        consumedProducts: consumedProducts,
        fallbackSwiftModules: fallbackSwiftModules,
      );
      await update(manifest, original, normalized);
    }
    if (rewriteDependencies != null) {
      for (final manifest in manifests) {
        final original = await manifest.readAsString();
        await update(manifest, original, await rewriteDependencies(original));
      }
    }
    return changed;
  }
}
