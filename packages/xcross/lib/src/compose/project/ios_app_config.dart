// ignore_for_file: prefer_constructors_over_static_methods

import 'dart:io';

import 'package:path/path.dart' as p;

final class IosAppConfig {
  const IosAppConfig({
    required this.productName,
    required this.bundleId,
    required this.marketingVersion,
    required this.currentProjectVersion,
    this.buildSettings = const {},
  });

  final String productName;
  final String bundleId;
  final String marketingVersion;
  final String currentProjectVersion;

  /// Every setting the xcconfig defines, with `$(VAR)` references expanded.
  /// Xcode substitutes these into Info.plist values at build time, and an
  /// app that reads configuration from its Info.plist depends on that.
  final Map<String, String> buildSettings;

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
      // `$()` is an empty setting in Xcode; projects use it to keep `//` in a
      // URL from starting an xcconfig comment (`https:/$()/example.com`).
      final token = RegExp(r'\$\(([^)]*)\)');
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
      buildSettings: {
        for (final entry in values.entries) entry.key: expand(entry.value),
      },
    );
  }

  static IosAppConfig? load(String root) {
    final appDir = directory(root);
    if (appDir == null) return null;
    final file = File(p.join(appDir, 'Configuration', 'Config.xcconfig'));
    if (!file.existsSync()) return null;
    return parse(file.readAsStringSync());
  }

  /// The iOS app project's directory: `<root>/iosApp`, or when there is none,
  /// the single `<root>/<dir>/iosApp` one level down.
  ///
  /// Compose projects commonly keep the app next to the shared module instead
  /// of at the root (`app/iosApp` beside `app/shared`). Missing it silently
  /// dropped the app's bundle id, Info.plist and entitlements, so the app was
  /// signed as `com.example.*` and aborted on its first Info.plist read.
  ///
  /// A directory only counts if it holds an Xcode project, a
  /// `Configuration/Config.xcconfig` or an Info.plist: xcross itself writes
  /// its runner build under `<root>/iosApp/.build`, which must not shadow the
  /// real app. Two nested candidates are ambiguous and resolve to neither.
  static String? directory(String root) {
    final direct = Directory(p.join(root, 'iosApp'));
    if (_isIosApp(direct)) return direct.path;
    final rootDir = Directory(root);
    if (!rootDir.existsSync()) return null;
    final nested = <String>[];
    for (final entry in rootDir.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (name.startsWith('.') || name == 'build') continue;
      final candidate = Directory(p.join(entry.path, 'iosApp'));
      if (_isIosApp(candidate)) nested.add(candidate.path);
    }
    return nested.length == 1 ? nested.single : null;
  }

  static bool _isIosApp(Directory dir) {
    if (!dir.existsSync()) return false;
    if (File(
          p.join(dir.path, 'Configuration', 'Config.xcconfig'),
        ).existsSync() ||
        File(p.join(dir.path, 'Info.plist')).existsSync() ||
        File(p.join(dir.path, 'iosApp', 'Info.plist')).existsSync()) {
      return true;
    }
    return dir
        .listSync(followLinks: false)
        .any(
          (entry) => entry is Directory && entry.path.endsWith('.xcodeproj'),
        );
  }
}
