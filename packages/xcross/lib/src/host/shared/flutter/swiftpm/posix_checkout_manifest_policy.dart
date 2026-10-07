import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_source_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_fallback.dart';

@internal
final class PosixSwiftPmVendoredManifestPolicy<T extends PlatformHostInterface>
    implements SwiftPmVendoredManifestPolicy {
  const PosixSwiftPmVendoredManifestPolicy({
    required this.sourceNormalizer,
    required this.sourceFallback,
  });
  final SwiftPmHostSourceNormalizer sourceNormalizer;
  final SwiftPmSourceFallback<T> sourceFallback;
  @override
  String normalizeHostManifest(String manifest) =>
      sourceNormalizer.normalizeHostManifest(manifest);
  @override
  String normalizeDetached(
    String manifest, {
    required Set<String> consumedProducts,
  }) => sourceFallback.aliasBinaryFallbackProducts(
    normalizeHostManifest(manifest),
    consumedProducts: consumedProducts,
  );
  @override
  Future<String> normalize(
    String manifest, {
    required String packageDir,
    required Set<String> consumedProducts,
    Map<String, List<String>>? fallbackSwiftModules,
  }) => sourceFallback.synthesizeBinaryFallbackCompatibility(
    normalizeHostManifest(manifest),
    packageDir: packageDir,
    consumedProducts: consumedProducts,
    fallbackSwiftModules: fallbackSwiftModules,
  );
}
