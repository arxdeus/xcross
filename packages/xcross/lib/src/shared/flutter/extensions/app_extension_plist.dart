import 'package:meta/meta.dart';
import 'package:xcross/src/device/internal/embedded_extension.dart';
import 'package:xcross/src/flutter/build/ios_app_extensions.dart';
import 'package:xcross/src/flutter/build/ios_bundle_versions.dart';

abstract final class AppExtensionPlist {
  static const fallback = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
''';
  static String expandExtensionVars(
    String xml, {
    required IosAppExtension extension,
    IosBundleVersions versions = IosBundleVersions.fallback,
  }) {
    final substitutions = <String, String>{
      'PRODUCT_BUNDLE_IDENTIFIER': extension.bundleId,
      'PRODUCT_NAME': extension.name,
      'EXECUTABLE_NAME': extension.executableName,
      'DEVELOPMENT_LANGUAGE': 'en',
      'FLUTTER_BUILD_NAME': versions.shortVersion,
      'FLUTTER_BUILD_NUMBER': versions.bundleVersion,
      'MARKETING_VERSION': versions.shortVersion,
      'CURRENT_PROJECT_VERSION': versions.bundleVersion,
      if (extension.appGroups.isNotEmpty)
        'CUSTOM_GROUP_ID': extension.appGroups.first,
    };

    var result = xml;
    for (final entry in substitutions.entries) {
      result = result
          .replaceAll('\$(${entry.key})', entry.value)
          .replaceAll('\${${entry.key}}', entry.value);
    }
    return result;
  }

  /// Set the keys iOS requires on an app extension, replacing existing ones.
  static String forceKeys(
    String xml, {
    required String bundleId,
    required String executableName,
    required String bundleName,
    required String minimumOsVersion,
    IosBundleVersions versions = IosBundleVersions.fallback,
  }) {
    var result = xml;
    final keys = <String, String>{
      'CFBundleIdentifier': bundleId,
      'CFBundleExecutable': executableName,
      'CFBundleName': bundleName,
      // installd rejects an appex without a non-empty CFBundleDisplayName
      // ("MissingBundleDisplayNameString"), even though apps may omit it.
      'CFBundleDisplayName': bundleName,
      'CFBundlePackageType': 'XPC!',
      'MinimumOSVersion': minimumOsVersion,
      'CFBundleInfoDictionaryVersion': '6.0',
      // iOS requires an extension's versions to match its host app's.
      'CFBundleShortVersionString': versions.shortVersion,
      'CFBundleVersion': versions.bundleVersion,
      'CFBundleDevelopmentRegion': 'en',
    };
    for (final entry in keys.entries) {
      result = setKey(result, entry.key, entry.value);
    }
    return result;
  }

  /// Record [appGroups] under [AppExtensionEntitlements.appGroupsInfoKey].
  static String setAppGroups(String xml, List<String> appGroups) {
    if (appGroups.isEmpty) return xml;
    const key = AppExtensionEntitlements.appGroupsInfoKey;
    final entries = appGroups
        .map((group) => '\n\t\t<string>$group</string>')
        .join();

    final existing = RegExp(
      '<key>\\s*${RegExp.escape(key)}\\s*</key>\\s*<array>.*?</array>',
      dotAll: true,
    );
    final replacement = '<key>$key</key>\n\t<array>$entries\n\t</array>';
    if (existing.hasMatch(xml)) {
      return xml.replaceFirst(existing, replacement);
    }

    final dictIndex = xml.indexOf('<dict>');
    if (dictIndex == -1) return xml;
    final insertAt = dictIndex + '<dict>'.length;
    return '${xml.substring(0, insertAt)}\n\t$replacement'
        '${xml.substring(insertAt)}';
  }

  /// Replace `<key>[key]</key><string>…</string>`, inserting when absent.
  @visibleForTesting
  static String setKey(String xml, String key, String value) {
    final pattern = RegExp(
      '<key>\\s*${RegExp.escape(key)}\\s*</key>\\s*<string>[^<]*</string>',
    );
    final replacement = '<key>$key</key>\n\t<string>$value</string>';
    if (pattern.hasMatch(xml)) {
      return xml.replaceFirst(pattern, replacement);
    }

    final dictIndex = xml.indexOf('<dict>');
    if (dictIndex == -1) return xml;
    final insertAt = dictIndex + '<dict>'.length;
    return '${xml.substring(0, insertAt)}\n\t$replacement'
        '${xml.substring(insertAt)}';
  }
}
