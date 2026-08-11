// ignore_for_file: prefer_constructors_over_static_methods

import 'dart:io';

import 'package:path/path.dart' as p;

final class IosAppConfig {
  const IosAppConfig({
    required this.productName,
    required this.bundleId,
    required this.marketingVersion,
    required this.currentProjectVersion,
  });

  final String productName;
  final String bundleId;
  final String marketingVersion;
  final String currentProjectVersion;

  static IosAppConfig parse(String content) {
    final values = <String, String>{};
    for (final rawLine in content.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('//') || line.startsWith('#')) {
        continue;
      }
      final suffixStart = line.indexOf('[');
      final equals = suffixStart >= 0
          ? line.indexOf('=', line.indexOf(']', suffixStart) + 1)
          : line.indexOf('=');
      if (equals < 0) continue;
      final rawKey = line.substring(0, equals).trim();
      final key = suffixStart >= 0 ? rawKey.substring(0, suffixStart) : rawKey;
      values[key.trim()] = line.substring(equals + 1).trim();
    }

    String expand(String value) {
      var expanded = value;
      final token = RegExp(r'\$\(([^)]+)\)');
      for (var i = 0; i < 8; i++) {
        final next = expanded.replaceAllMapped(
          token,
          (match) => values[match.group(1)!] ?? '',
        );
        if (next == expanded) break;
        expanded = next;
      }
      return expanded.replaceAll(token, '');
    }

    return IosAppConfig(
      productName: expand(values['PRODUCT_NAME'] ?? 'Runner'),
      bundleId: expand(values['PRODUCT_BUNDLE_IDENTIFIER'] ?? ''),
      marketingVersion: expand(values['MARKETING_VERSION'] ?? '1.0'),
      currentProjectVersion: expand(values['CURRENT_PROJECT_VERSION'] ?? '1'),
    );
  }

  static IosAppConfig? load(String root) {
    final file = File(
      p.join(root, 'iosApp', 'Configuration', 'Config.xcconfig'),
    );
    if (!file.existsSync()) return null;
    return parse(file.readAsStringSync());
  }
}
