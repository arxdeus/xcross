import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_provenance.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_git_repository.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_dependencies.dart';

final class WindowsSwiftPmPinnedDependencyResolver<
  T extends PlatformHostInterface
> {
  WindowsSwiftPmPinnedDependencyResolver({
    required this.runner,
    required this.fileSystem,
    required this.filesystem,
    required this.repository,
    required this.manifestNormalizer,
  });
  final ProcessRunner<T> runner;
  final SwiftPmArtifactFileSystem fileSystem;
  final SwiftPmFilesystem<T> filesystem;
  final SwiftPmGitPackageCloner repository;
  final SwiftPmCheckoutManifestNormalizer<T> manifestNormalizer;

  /// SwiftPM evaluates remote manifests before checkout normalization can fix
  /// host-incompatible declarations. Prestage deterministically pinned Git
  /// dependencies through normalized local checkouts for the resolve pass,
  /// then restore the original plugin manifests for normal vendoring. Leave
  /// version ranges to SwiftPM's solver rather than choosing a version here.
  Future<({Map<String, String> pins, Map<String, String> originals})> resolve(
    Iterable<String> packageDirectories,
    String vendorDir,
  ) async {
    final originals = <String, String>{};
    final rewrites = <String, String>{};
    final pins = <String, String>{};
    final replacements = <String, String>{};
    final manifests = <String, String>{};
    final urls = <String, String>{};
    final products = <String, Set<String>>{};
    final unpinned = <String>{};
    String? git;
    for (final directory in packageDirectories) {
      final manifestFile = fileSystem.file(p.join(directory, 'Package.swift'));
      if (!manifestFile.existsSync()) continue;
      final original = await manifestFile.readAsString();
      manifests[manifestFile.path] = original;
      for (final dependency in SwiftPmManifestDependencies.parseUrlPackageDeps(
        original,
      )) {
        final identity = SwiftPmBinaryProvenance.canonicalGitUrl(
          dependency.url,
        );
        final ref = RegExp(
          r'\b(?:exact|revision)\s*:\s*"([^"\r\n]+)"',
        ).firstMatch(dependency.match)?[1];
        if (ref == null) {
          unpinned.add(identity);
          continue;
        }
        final previousRef = pins[identity];
        if (previousRef != null && previousRef != ref) {
          throw FlutterBuildError(
            'Conflicting pinned refs for $identity: $previousRef and $ref',
          );
        }
        pins[identity] = ref;
        urls.putIfAbsent(identity, () => dependency.url);
        products
            .putIfAbsent(identity, () => <String>{})
            .addAll(
              SwiftPmManifestDependencies.consumedProducts(
                original,
                dependency.identity,
              ),
            );
      }
    }
    // A range for the same URL must continue through SwiftPM's solver.
    for (final identity in unpinned) {
      pins.remove(identity);
      urls.remove(identity);
      products.remove(identity);
    }
    for (final entry in pins.entries) {
      final identity = entry.key;
      final ref = entry.value;
      final url = urls[identity]!;
      final destination = p.join(
        vendorDir,
        SwiftPmManifestDependencies.vendorPackageDirName(url, ref),
      );
      git ??= await runner.locateTool('git');
      await repository.cloneGitPackage(git, url, ref, destination);
      await manifestNormalizer.normalizeVendoredPackageManifests(
        destination,
        consumedProducts: products[identity]!,
      );
      replacements[identity] = destination;
    }
    for (final entry in manifests.entries) {
      var rewritten = entry.value;
      for (final dependency in SwiftPmManifestDependencies.parseUrlPackageDeps(
        entry.value,
      )) {
        final identity = SwiftPmBinaryProvenance.canonicalGitUrl(
          dependency.url,
        );
        if (!replacements.containsKey(identity)) continue;
        rewritten = rewritten.replaceAll(
          dependency.match,
          '.package(name: "${dependency.identity}", '
          'path: "${SwiftPmFilesystem.swiftPath(replacements[identity]!)}")',
        );
      }
      if (rewritten != entry.value) {
        originals[entry.key] = entry.value;
        rewrites[entry.key] = rewritten;
      }
    }
    try {
      for (final entry in rewrites.entries) {
        await filesystem.writeStable(entry.key, entry.value);
      }
    } on Object {
      for (final entry in originals.entries) {
        await filesystem.writeStable(entry.key, entry.value);
      }
      rethrow;
    }
    return (pins: pins, originals: originals);
  }

  /// Pins every URL dependency reachable from [packageDirectories] with a
  /// single `swift package resolve`, so each package identity maps to exactly
  /// one revision across the whole plugin graph. Returns null when nothing
  /// declares a URL dependency.
  ///
  /// SwiftPM only sees dependencies a checkout's manifest declares for the
  /// host, so entries firebase-ios-sdk hides behind `#if os(macOS)` are never
  /// pinned. Each round scans the resolved checkouts for such unpinned deps,
  /// re-declares them on the resolve root (root dependencies are the only
  /// ones SwiftPM never prunes as unused), and resolves again until the pins
  /// cover the graph.
}
