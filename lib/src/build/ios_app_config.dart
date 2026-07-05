import 'dart:io';

import 'package:path/path.dart' as p;

/// Parsed values from `iosApp/Configuration/Config.xcconfig`.
///
/// Used by [ComposePacker] Stage 9 to populate a complete Info.plist for
/// SwiftUI-hosted apps ([KmpEntryKind.swiftApp]) instead of deriving identity
/// from `xtool.yml` (which often does not exist in a pure KMP project).
///
/// Parsing rules:
///   - Lines starting with `//` (after trimming) are comments → ignored.
///   - Each remaining non-empty line is split on the FIRST `=`.
///   - `$(VAR)` tokens are expanded against the same parsed map (single-pass).
///   - Any still-unresolved `$(…)` tokens are stripped (e.g. empty TEAM_ID).
class IosAppConfig {
  const IosAppConfig({
    required this.productName,
    required this.bundleId,
    required this.marketingVersion,
    required this.currentProjectVersion,
  });

  /// Parse raw xcconfig [content] string into an [IosAppConfig].
  ///
  /// Named factory constructor — lets unit tests parse in-memory content
  /// without file I/O. The parsing logic is identical to [load].
  factory IosAppConfig.parse(String content) {
    return _build(content);
  }

  /// PRODUCT_NAME, e.g. `KotlinProject`.
  final String productName;

  /// PRODUCT_BUNDLE_IDENTIFIER, fully expanded + sanitized,
  /// e.g. `org.example.project.KotlinProject`.
  /// Empty-string TEAM_ID (a common xcconfig pattern) is collapsed away.
  final String bundleId;

  /// MARKETING_VERSION, e.g. `1.0`. Defaults to `'1.0'` if absent.
  final String marketingVersion;

  /// CURRENT_PROJECT_VERSION, e.g. `1`. Defaults to `'1'` if absent.
  final String currentProjectVersion;

  // ---------------------------------------------------------------------------
  // Factory / loading
  // ---------------------------------------------------------------------------

  /// Load and parse `<projectRoot>/iosApp/Configuration/Config.xcconfig`.
  ///
  /// Returns `null` when the file does not exist (the packer falls back to
  /// deriving identity from `xtool.yml` / bundle-id logic).
  static IosAppConfig? load(String projectRoot) {
    final file = File(
        p.join(projectRoot, 'iosApp', 'Configuration', 'Config.xcconfig'));
    if (!file.existsSync()) return null;
    return _build(file.readAsStringSync());
  }

  // ---------------------------------------------------------------------------
  // Internal parsing
  // ---------------------------------------------------------------------------

  static final _varRe = RegExp(r'\$\(([^)]+)\)');

  // ignore: prefer_constructors_over_static_methods
  static IosAppConfig _build(String content) {
    // ── Step 1: collect raw KEY=VALUE pairs ──────────────────────────────────
    final raw = <String, String>{};
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('//')) continue;
      final eqIdx = trimmed.indexOf('=');
      if (eqIdx < 0) continue;
      final key = trimmed.substring(0, eqIdx).trim();
      final value = trimmed.substring(eqIdx + 1).trim();
      raw[key] = value;
    }

    // ── Step 2: expand $(VAR) references (single-pass against raw map) ───────
    // Undefined variables and empty-value variables both resolve to ''.
    // A trailing $(TEAM_ID) with TEAM_ID='' → '' → the prefix is kept clean.
    String expand(String val) =>
        val.replaceAllMapped(_varRe, (m) => raw[m.group(1)!] ?? '');

    final expanded = raw.map((k, v) => MapEntry(k, expand(v)));

    // ── Step 3: strip any still-unresolved $(…) tokens, then trim ────────────
    String clean(String? v) {
      if (v == null || v.isEmpty) return '';
      return v.replaceAll(_varRe, '').trim();
    }

    final productName = clean(expanded['PRODUCT_NAME']);
    final bundleId = clean(expanded['PRODUCT_BUNDLE_IDENTIFIER']);
    final marketingVersion = clean(expanded['MARKETING_VERSION']);
    final currentProjectVersion = clean(expanded['CURRENT_PROJECT_VERSION']);

    return IosAppConfig(
      productName: productName.isNotEmpty ? productName : 'Runner',
      bundleId: bundleId,
      marketingVersion: marketingVersion.isNotEmpty ? marketingVersion : '1.0',
      currentProjectVersion:
          currentProjectVersion.isNotEmpty ? currentProjectVersion : '1',
    );
  }

  @override
  String toString() =>
      'IosAppConfig(productName=$productName, bundleId=$bundleId, '
      'marketingVersion=$marketingVersion, '
      'currentProjectVersion=$currentProjectVersion)';
}
