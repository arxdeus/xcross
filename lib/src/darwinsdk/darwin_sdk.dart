import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/process.dart';

/// An xcross-owned Swift SDK artifact bundle containing the Darwin SDK files
/// needed to build for iOS.
class DarwinSdk {
  DarwinSdk(this.bundle);

  /// Root of `xcross-darwin.artifactbundle`.
  final String bundle;

  static final RegExp _digitPattern = RegExp('[0-9]');

  /// Artifact bundle path passed to SwiftPM's `--swift-sdk-path` option.
  String get swiftSdkPath => bundle;

  /// Where `xcross sdk install <Xcode.xip>` installs the Swift SDK bundle.
  static String nativeInstallDir({String? configDir}) => p.join(
    configDir ?? _configDir(),
    'xcross',
    'swift-sdks',
    'xcross-darwin.artifactbundle',
  );

  /// Resolve the SDK installed and owned by xcross, or null when incomplete.
  static DarwinSdk? current({String? bundle}) {
    final candidate = bundle ?? nativeInstallDir();
    return isValidBundle(candidate) ? DarwinSdk(candidate) : null;
  }

  /// A complete bundle has Swift artifact metadata and a usable iPhoneOS SDK.
  static bool isValidBundle(String candidate) {
    if (!File(p.join(candidate, 'info.json')).existsSync() ||
        !File(p.join(candidate, 'swift-sdk.json')).existsSync()) {
      return false;
    }

    final sdk = _firstSdk(_sdksDir(candidate, 'iPhoneOS'), 'iPhoneOS');
    return sdk != null &&
        Directory(p.join(sdk, 'System', 'Library', 'Frameworks')).existsSync();
  }

  /// First versioned iPhoneOSXX.X.sdk found, else first iPhoneOS.sdk.
  String iPhoneOSSdk() {
    final dir = _sdksDir(bundle, 'iPhoneOS');
    final pick = _firstSdk(dir, 'iPhoneOS');
    if (pick == null) {
      throw XcrossError(
        'DarwinSdk: Could not find an iPhoneOS SDK under $dir.\n'
        'Install one with `xcross sdk install <Xcode.xip>`.',
      );
    }
    return pick;
  }

  static String _sdksDir(String bundle, String platform) => p.join(
    bundle,
    'Developer',
    'Platforms',
    '$platform.platform',
    'Developer',
    'SDKs',
  );

  static String? _firstSdk(String dir, String prefix) {
    if (!Directory(dir).existsSync()) return null;
    final entries =
        Directory(dir)
            .listSync()
            .where(
              (entry) =>
                  entry is Directory ||
                  FileSystemEntity.typeSync(entry.path) ==
                      FileSystemEntityType.directory,
            )
            .map((entry) => p.basename(entry.path))
            .where((name) => name.startsWith(prefix) && name.endsWith('.sdk'))
            .toList()
          ..sort();

    final versioned = entries
        .where((name) => name.contains(_digitPattern))
        .firstOrNull;
    final pick = versioned ?? entries.firstOrNull;
    return pick == null ? null : p.join(dir, pick);
  }

  static String _configDir() {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) return appData;
    }
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.isNotEmpty) return xdg;
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return p.join(home, '.config');
  }
}

/// Resolve the Apple-compatible linker from PATH on every host.
Future<String> resolveLd64Lld(DarwinSdk _) =>
    ProcessRunner.locateTool('ld64.lld');
