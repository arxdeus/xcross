import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_lexer.dart';

final class SwiftPmManifestDependencies {
/// Parses remote `.package(url:)` entries out of a Swift manifest.
  ///
  /// Uses parenthesis balancing so nested forms like
  /// `.upToNextMajor(from: "1.0.0")` are not truncated at the inner `)`.
  static List<SwiftPmPackageDependency> parseUrlPackageDeps(String manifest) {
    final deps = <SwiftPmPackageDependency>[];
    final constants = SwiftPmManifestLexer.manifestStringConstants(manifest);
    var searchFrom = 0;
    final startPattern = RegExp(r'\.package\s*\(');
    while (true) {
      final startMatch = startPattern
          .allMatches(manifest, searchFrom)
          .firstOrNull;
      if (startMatch == null) break;
      final start = startMatch.start;
      final open = startMatch.end - 1; // '('
      final close = SwiftPmManifestLexer.indexOfMatchingParen(manifest, open);
      if (close < 0) break;
      final inner = manifest.substring(open + 1, close);
      final urlMatch = RegExp(
        r'url:\s*(?:"(?<literal>[^"]+)"|(?<constant>[A-Za-z_]\w*)\b(?!\s*\.))',
      ).firstMatch(inner);
      final url =
          urlMatch?.namedGroup('literal') ??
          constants[urlMatch?.namedGroup('constant')];
      if (url == null) {
        searchFrom = close + 1;
        continue;
      }
      final nameMatch = RegExp(r'name:\s*"(?<name>[^"]*)"').firstMatch(inner);
      final name = nameMatch?.namedGroup('name');
      deps.add(
        SwiftPmPackageDependency(
          name: name,
          url: url,
          identity: name ?? SwiftPmManifestDependencies.packageIdentityFromUrl(url),
          match: manifest.substring(start, close + 1),
        ),
      );
      searchFrom = close + 1;
    }
    return deps;
  }

/// Folder name for a vendored checkout of [url] at [ref].
  static String vendorPackageDirName(String url, String ref) {
    final safeRef = ref.replaceAll(RegExp(r'[^\w.\-]+'), '_');
    final identity = SwiftPmManifestDependencies.packageIdentityFromUrl(url);
    if (identity == 'firebase-ios-sdk') {
      return 'fb@${safeRef.length > 12 ? safeRef.substring(0, 12) : safeRef}';
    }
    return '$identity@$safeRef';
  }

/// Swift tools version declared by [manifest], or `null` when absent.
  ///
  /// `.package(name:path:)` only exists from PackageDescription 5.2, so a
  /// vendored manifest older than that (SDWebImageWebPCoder pins 5.0) must
  /// get a plain `.package(path:)`. Pre-5.2 SwiftPM derives the dependency
  /// name from the dependency's own `Package(name:)`, so target references
  /// keep resolving without an explicit `name:`.
  static ({int major, int minor})? manifestToolsVersion(String manifest) {
    final match = RegExp(
      r'^//\s*swift-tools-version\s*:?\s*(\d+)(?:\.(\d+))?',
      multiLine: true,
    ).firstMatch(manifest);
    if (match == null) return null;
    return (
      major: int.parse(match.group(1)!),
      minor: int.tryParse(match.group(2) ?? '0') ?? 0,
    );
  }

static bool supportsNamedPathDeps(String manifest) {
    final version = SwiftPmManifestDependencies.manifestToolsVersion(manifest);
    if (version == null) return true;
    return version.major > 5 || (version.major == 5 && version.minor >= 2);
  }

/// SwiftPM package identity implied by a git URL (last path segment, no
  /// `.git`). Used as `.package(name:)` so target `package:` references keep
  /// matching after we vendor into a `name@version` directory.
  static String packageIdentityFromUrl(String url) {
    var identity = Uri.parse(url).pathSegments.lastWhere(
      (segment) => segment.isNotEmpty,
      orElse: () => 'package',
    );
    if (identity.endsWith('.git')) {
      identity = identity.substring(0, identity.length - 4);
    }
    return identity;
  }

static Set<String> consumedProducts(String manifest, String package) {
    final products = <String>{};
    for (final call in SwiftPmManifestLexer.swiftCalls(manifest, '.product')) {
      if (SwiftPmManifestLexer.namedString(call.text, 'package') == package) {
        final name = SwiftPmManifestLexer.namedString(call.text, 'name');
        if (name != null) products.add(name);
      }
    }
    return products;
  }
}
