import 'dart:io';
import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/compose/project/ios_app_config.dart';
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/flutter/constants.dart';

abstract final class ComposeInfoPlist {
  static String build({
    required KmpProject project,
    Map<String, Object?> extras = const {},
  }) {
    final merged = <String, Object?>{..._composeDefaults};
    final partial = _readPartial(project.root);
    if (partial != null) {
      merged.addAll(
        _expandMap(_safeMap(partial, 'partial plist'), _buildSettings(project)),
      );
    }
    merged.addAll(_safeMap(extras, 'extras'));
    merged.addAll(_required(project));
    return PropertyListSerialization.stringWithPropertyList(merged);
  }

  /// Defaults a Compose app needs but Xcode templates normally supply.
  ///
  /// Compose UI runs `PlistSanityCheck` on startup and *throws* (SIGABRT
  /// inside `terminateWithUnhandledException`, confirmed on device) when
  /// `CADisableMinimumFrameDurationOnPhone` is missing, because without it
  /// iOS caps the app at 60Hz on ProMotion displays. Xcode projects get the
  /// key from the template's Info.plist, so a generated bundle must add it
  /// or every Compose app crashes to a black screen at launch.
  ///
  /// These are defaults, not overrides: the project's own partial plist and
  /// explicit extras are merged on top.
  static const _composeDefaults = <String, Object?>{
    'CADisableMinimumFrameDurationOnPhone': true,
  };

  static Map<String, Object?> _required(KmpProject project) {
    final config = project.iosConfig;
    final appName = project.appName;
    final bundleId = project.bundleId;
    return {
      'CFBundleExecutable': 'Runner',
      'CFBundleIdentifier': bundleId,
      'CFBundleName': appName,
      'CFBundleDisplayName': appName,
      'CFBundleShortVersionString': config?.marketingVersion ?? '1.0',
      'CFBundleVersion': config?.currentProjectVersion ?? '1',
      'CFBundlePackageType': 'APPL',
      'LSRequiresIPhoneOS': true,
      IosDeploymentConstants.minimumOsVersionKey: '15.0',
      'CFBundleSupportedPlatforms': ['iPhoneOS'],
      'UIRequiredDeviceCapabilities': ['arm64'],
      'UIDeviceFamily': [1],
      'UILaunchScreen': <String, Object?>{},
      'DTPlatformName': 'iphoneos',
      'DTSDKName': IosDeploymentConstants.sdkTriple,
      'DTPlatformVersion': IosDeploymentConstants.sdkVersion,
    };
  }

  /// What Xcode would substitute for `$(VAR)` in this app's Info.plist: the
  /// xcconfig's settings plus the identity this build actually uses.
  static Map<String, String> _buildSettings(KmpProject project) {
    final config = project.iosConfig;
    return {
      ...?config?.buildSettings,
      'PRODUCT_BUNDLE_IDENTIFIER': project.bundleId,
      'PRODUCT_NAME': project.appName,
      'EXECUTABLE_NAME': 'Runner',
      'DEVELOPMENT_LANGUAGE': 'en',
      'MARKETING_VERSION': config?.marketingVersion ?? '1.0',
      'CURRENT_PROJECT_VERSION': config?.currentProjectVersion ?? '1',
    };
  }

  /// Substitutes `$(VAR)` and `${VAR}` in every string, like Xcode's Info.plist
  /// preprocessing. An unknown setting expands to nothing, as in Xcode.
  ///
  /// Copying the file verbatim left an app that reads configuration from its
  /// Info.plist (an API base URL, an OAuth client id) with the literal text
  /// `$(API_BASE_URL)`, which such an app rightly refuses at launch.
  static Map<String, Object?> _expandMap(
    Map<String, Object?> map,
    Map<String, String> settings,
  ) => {
    for (final entry in map.entries) entry.key: _expand(entry.value, settings),
  };

  static Object? _expand(Object? value, Map<String, String> settings) {
    if (value is String) {
      return value.replaceAllMapped(
        RegExp(r'\$\(([A-Za-z0-9_]+)\)|\$\{([A-Za-z0-9_]+)\}'),
        (match) {
          final name = match.group(1) ?? match.group(2)!;
          final expanded = settings[name];
          if (expanded == null) {
            Log.logWarn(
              'Info.plist references \$($name), which no build setting '
              'defines. It expands to an empty string.',
            );
          }
          return expanded ?? '';
        },
      );
    }
    if (value is List) {
      return value.map((item) => _expand(item, settings)).toList();
    }
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          entry.key as String: _expand(entry.value, settings),
      };
    }
    return value;
  }

  static Map<String, Object?>? _readPartial(String root) {
    final appDir = IosAppConfig.directory(root);
    final candidates = [
      if (appDir != null) ...[
        p.join(appDir, 'iosApp', 'Info.plist'),
        p.join(appDir, 'Info.plist'),
      ],
      p.join(root, 'iosApp', 'iosApp', 'Info.plist'),
      p.join(root, 'iosApp', 'Info.plist'),
    ];
    for (final path in candidates) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final object = PropertyListSerialization.propertyListWithString(
        file.readAsStringSync(),
      );
      if (object is! Map) {
        throw XcrossError(
          'Compose Info.plist root must be a dictionary: $path',
        );
      }
      return object.cast<String, Object?>();
    }
    return null;
  }

  static Map<String, Object?> _safeMap(
    Map<Object?, Object?> map,
    String source,
  ) {
    final result = <String, Object?>{};
    for (final entry in map.entries) {
      final key = entry.key;
      if (key is! String || key.isEmpty) {
        throw XcrossError('Unsafe $source key: $key');
      }
      result[key] = _safeValue(entry.value, '$source.$key');
    }
    return result;
  }

  static Object? _safeValue(Object? value, String path) {
    if (value == null ||
        value is String ||
        value is int ||
        value is double ||
        value is bool) {
      return value;
    }
    if (value is Float32) return value;
    if (value is List) {
      return value
          .map((item) => _safeValue(item, path))
          .toList(growable: false);
    }
    if (value is Map) return _safeMap(value.cast<Object?, Object?>(), path);
    throw XcrossError('Unsafe plist value at $path: ${value.runtimeType}');
  }
}
