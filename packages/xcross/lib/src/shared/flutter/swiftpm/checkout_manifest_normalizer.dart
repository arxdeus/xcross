import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_dependencies.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_lexer.dart';

@internal
abstract interface class SwiftPmVendoredManifestPolicy {
  String normalizeHostManifest(String manifest);
  String normalizeDetached(
    String manifest, {
    required Set<String> consumedProducts,
  });
  Future<String> normalize(
    String manifest, {
    required String packageDir,
    required Set<String> consumedProducts,
    Map<String, List<String>>? fallbackSwiftModules,
  });
}

@internal
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
  Future<SwiftPmCheckoutFallbacks> synthesizeCheckoutFallbacks(
    String scratchPath, {
    required Map<String, Set<String>> consumedProducts,
  }) async {
    final swiftModules = <String, List<String>>{};
    final consumers = <String>[];
    final fallbackIdentities = <String>{};
    final checkouts = fileSystem.directory(p.join(scratchPath, 'checkouts'));
    if (!checkouts.existsSync()) {
      return const SwiftPmCheckoutFallbacks(
        swiftModules: {},
        consumedProducts: {},
      );
    }
    final packages =
        checkouts.listSync(followLinks: false).whereType<Directory>().toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final package in packages) {
      final packageDir = fileSystem.processPath(package.path);
      final identity = p.basename(packageDir).toLowerCase();
      final manifests =
          package.listSync(followLinks: false).whereType<File>().where((file) {
            final name = p.basename(file.path);
            return name == 'Package.swift' ||
                (name.startsWith('Package@') && name.endsWith('.swift'));
          }).toList()..sort((a, b) => a.path.compareTo(b.path));
      for (final manifest in manifests) {
        final original = await manifest.readAsString();
        if (SwiftPmManifestLexer.fallbackBlock(
              policy.normalizeHostManifest(original),
            ) !=
            null) {
          fallbackIdentities.add(identity);
        }
        consumers.add(
          await policy.normalize(
            original,
            packageDir: packageDir,
            consumedProducts: {...?consumedProducts[identity]},
            fallbackSwiftModules: swiftModules,
          ),
        );
      }
    }
    final consumed = SwiftPmManifestDependencies.consumedProductsByIdentity(
      consumers,
    )..removeWhere((identity, _) => !fallbackIdentities.contains(identity));
    return SwiftPmCheckoutFallbacks(
      swiftModules: swiftModules,
      consumedProducts: consumed,
    );
  }
}

@internal
@immutable
final class SwiftPmCheckoutFallbacks {
  const SwiftPmCheckoutFallbacks({
    required this.swiftModules,
    required this.consumedProducts,
  });
  final Map<String, List<String>> swiftModules;
  final Map<String, Set<String>> consumedProducts;
}
