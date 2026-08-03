/// Base URL for Flutter engine and artifact downloads.
const String flutterArtifactBaseUrl =
    'https://storage.googleapis.com/flutter_infra_release/flutter';

/// DevFS and related Flutter-on-device constants.
abstract final class FlutterDeviceConstants {
  /// Name of the DevFS filesystem registered with the Dart VM.
  static const String devFsName = 'xcross';
}

/// Constants describing the iOS deployment target and SDK versions.
abstract final class IosDeploymentConstants {
  /// Minimum iOS deployment target version.
  static const String minDeploymentTarget = '13.0';

  /// Clang build triple for the arm64 iOS 13 deployment target.
  static const String buildTriple = 'arm64-apple-ios13.0';

  /// Hardcoded iOS SDK version written into Info.plist.
  static const String sdkVersion = '18.0';

  /// iOS SDK triple used for linking and plist metadata.
  static const String sdkTriple = 'iphoneos18.0';

  /// Info.plist key for the minimum OS version.
  static const String minimumOsVersionKey = 'MinimumOSVersion';
}

/// Constants for the generated Flutter-plugins Swift package.
abstract final class GeneratedPluginsConstants {
  /// `@_cdecl` symbol the generated Swift registrant exports.
  static const String registrantSymbol = 'XcrossRegisterGeneratedPlugins';
}

/// Default values written into an iOS app bundle's Info.plist.
abstract final class PlistDefaults {
  /// Default CFBundleShortVersionString (FLUTTER_BUILD_NAME).
  static const String shortVersion = '1.0.0';

  /// Default CFBundleVersion (FLUTTER_BUILD_NUMBER).
  static const String bundleVersion = '1';

  /// Default CFBundleExecutable and product name.
  static const String executable = 'Runner';
}
