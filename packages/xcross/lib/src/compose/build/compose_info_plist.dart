import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/flutter/constants.dart';

abstract final class ComposeInfoPlist {
  static String build({
    required KmpProject project,
    Map<String, Object?> extras = const {},
  }) {
    final merged = <String, Object?>{};
    final partial = _readPartial(project.root);
    if (partial != null) merged.addAll(_safeMap(partial, 'partial plist'));
    merged.addAll(_safeMap(extras, 'extras'));
    merged.addAll(_required(project));
    return PropertyListSerialization.stringWithPropertyList(merged);
  }

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

  static Map<String, Object?>? _readPartial(String root) {
    final candidates = [
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
