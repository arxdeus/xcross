import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_artifact_preparer.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_target.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_destination_publisher.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dynamic_product.dart';
import 'package:xcross/src/shared/flutter/swiftpm/resource_manifest.dart';

@internal
typedef PrepareSwiftPmBinaryArtifact =
    Future<SwiftPmPreparedBinaryArtifact> Function(
      SwiftPmRemoteBinaryTarget target,
    );
@internal
typedef CreateSwiftPmBinaryAlias =
    Future<void> Function({required String alias, required String target});
@internal
typedef MaterializeSwiftPmBinaryArtifact =
    Future<SwiftPmBinaryArtifactPublication> Function({
      required String source,
      required String destination,
    });

@internal
final class SwiftPmPackageDependency<T extends PlatformHostInterface> {
  const SwiftPmPackageDependency({
    required this.name,
    required this.url,
    required this.identity,
    required this.match,
  });

  final String? name;
  final String url;
  final String identity;
  final String match;
}

@internal
final class SwiftPmBinaryArtifactProvenance<T extends PlatformHostInterface> {
  const SwiftPmBinaryArtifactProvenance({
    required this.packageIdentity,
    required this.target,
    required this.manifestPath,
  });

  final String packageIdentity;
  final SwiftPmRemoteBinaryTarget target;
  final String manifestPath;
}

@internal
final class SwiftPmBinaryAttemptState {
  final Set<String> finalRecovered = {};
  final Set<String> copied = {};
}

/// The products of one SwiftPM build of an aggregate dynamic product.
@internal
final class SwiftPmBuildResult {
  const SwiftPmBuildResult({
    required this.libraryPath,
    required this.dylibPaths,
    required this.modulesDir,
    this.dynamicProducts = const [],
    this.frameworkPaths = const [],
    this.resourceBundlePaths = const [],
    this.resourceBundles = const [],
  });

  /// The aggregate product's dylib (`lib<productName>.dylib`).
  final String libraryPath;
  final List<String> dylibPaths;

  /// [dylibPaths] as the frameworks the app embeds them as.
  final List<SwiftPmDynamicProduct> dynamicProducts;
  final List<String> frameworkPaths;

  /// SwiftPM resource bundles (`<Package>_<Target>.bundle`, e.g. package
  /// privacy manifests) that Xcode copies into the application root.
  final List<String> resourceBundlePaths;

  /// [resourceBundlePaths] with the resources SwiftPM's build manifest
  /// copies into each, so they can be copied from their sources as Xcode does.
  final List<SwiftPmResourceBundle> resourceBundles;
  final String? modulesDir;
}

@internal
typedef ArtifactJunctionCapabilityResolver =
    Future<({bool swiftPmArtifact, bool packageLocalArtifact})> Function();
