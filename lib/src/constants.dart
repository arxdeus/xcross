/// Base URL for Flutter engine and artifact downloads.
const String flutterArtifactBaseUrl =
    'https://storage.googleapis.com/flutter_infra_release/flutter';

/// Constants for device connectivity and interactive keypress handling.
abstract final class DeviceConstants {
  /// VM service port used when launching the app on device.
  static const int vmServicePort = 12345;

  /// RSD service name for the Apple remote debug proxy.
  static const String debugproxyService =
      'com.apple.internal.dt.remote.debugproxy';

  /// Default tunneld REST API base URL.
  static const String tunneldUrl = 'http://127.0.0.1:49151/';

  /// Name of the DevFS filesystem registered with the Dart VM.
  static const String devFsName = 'xcross';

  /// Marker printed when the on-device VM Service is live; the DAP scans child
  /// stdout for it (by substring, so a line glyph may precede it) to emit
  /// `flutter.appStarted`. Keep the colon — it is what stops a stray mention of
  /// "vm-service" in the app's own output from being parsed as the URI line.
  static const String vmServiceMarker = 'vm-service: ';

  /// Keycode for 'q' — quits the running session.
  static const int keyQ = 0x71;

  /// Keycode for 'r' — triggers a hot reload.
  static const int keyR = 0x72;

  /// Keycode for 'R' — triggers a hot restart.
  static const int keyBigR = 0x52;

  /// Keycode for Ctrl-C — terminates the session.
  static const int keyCtrlC = 0x03;

  /// Keycode for Ctrl-D — terminates the session.
  static const int keyCtrlD = 0x04;
}

/// Constants describing the iOS deployment target and SDK versions.
abstract final class IosDeploymentConstants {
  /// Minimum iOS deployment target version.
  static const String minDeploymentTarget = '13.0';

  /// Clang build triple for the arm64 iOS 13 deployment target.
  static const String buildTriple = 'arm64-apple-ios13.0';

  /// Hardcoded iOS SDK version written into Info.plist. Nothing sniffs the
  /// installed SDK; this deliberately differs from the linker's fallback SDK
  /// version in runner_shim.dart. Do not unify the two.
  static const String sdkVersion = '18.0';

  /// iOS SDK triple used for linking and plist metadata.
  static const String sdkTriple = 'iphoneos18.0';

  /// Info.plist key for the minimum OS version.
  static const String minimumOsVersionKey = 'MinimumOSVersion';
}

/// Constants for the generated Flutter-plugins Swift package (see
/// `GeneratedPluginsPackage` in ios_plugin_package.dart and `RunnerShim`).
abstract final class GeneratedPluginsConstants {
  /// `@_cdecl` symbol the generated Swift registrant exports, and that
  /// `Runner.m` calls via a plain `extern` forward declaration. Must match
  /// exactly between the Swift codegen (ios_plugin_package.dart) and the
  /// ObjC codegen (runner_shim.dart) — they're compiled/linked as separate
  /// binaries and only connected by this symbol name at link time.
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
