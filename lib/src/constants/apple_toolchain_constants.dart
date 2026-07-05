/// Constants for Apple toolchain shims used in the compose build pipeline.
abstract final class AppleToolchainConstants {
  /// Xcode version string reported by the xcrun shim.
  static const String xcodeVersion = 'Xcode 16.0';

  /// Xcode build version string reported by the xcrun shim.
  static const String xcodeBuild = '16A242d';

  /// Absolute path to the PlistBuddy utility (or its shim).
  static const String plistBuddy = '/usr/libexec/PlistBuddy';

  /// Absolute path to the xcode-select utility (or its shim).
  static const String xcodeSelect = '/usr/bin/xcode-select';

  /// Absolute path to the xcrun utility (or its shim).
  static const String xcrun = '/usr/bin/xcrun';
}
