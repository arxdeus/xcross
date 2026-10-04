import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_source_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_fallback.dart';

@internal
final class WindowsSwiftPmVendoredManifestPolicy<
  T extends PlatformHostInterface
>
    implements SwiftPmVendoredManifestPolicy {
  const WindowsSwiftPmVendoredManifestPolicy({
    required this.sourceNormalizer,
    required this.sourceFallback,
  });
  final SwiftPmHostSourceNormalizer sourceNormalizer;
  final SwiftPmSourceFallback<T> sourceFallback;
  @override
  String normalizeHostManifest(String manifest) {
    final normalized = sourceNormalizer.normalizeHostManifest(manifest);
    return normalized.replaceAllMapped(
      RegExp(r'#elseif\s+canImport\(MSVCRT\)\r?\nimport MSVCRT'),
      (match) {
        final prefix = normalized.substring(0, match.start);
        if (prefix.endsWith(
          '#elseif canImport(CRT)\n'
          'import CRT\n'
          '#elseif canImport(ucrt)\n'
          'import ucrt\n',
        )) {
          return match.group(0)!;
        }
        return '#elseif canImport(CRT)\n'
            'import CRT\n'
            '#elseif canImport(ucrt)\n'
            'import ucrt\n'
            '#elseif canImport(MSVCRT)\n'
            'import MSVCRT';
      },
    );
  }

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
