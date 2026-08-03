import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;

import 'package:darwin_sdk_kit/src/errors.dart';

/// An xcross-owned Swift SDK artifact bundle containing the Darwin SDK files
/// needed to build for iOS.
class DarwinSdk {
  DarwinSdk(this.bundle);

  /// Root of `xcross-darwin.artifactbundle`.
  final String bundle;

  static final RegExp _digitPattern = RegExp('[0-9]');

  /// Artifact bundle path whose parent is passed to `--swift-sdks-path`.
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
    final source = _canonicalLayout(candidate);
    final destination = _runtimeLayout(candidate);
    try {
      if ((!destination.existsSync() || destination.lengthSync() == 0) &&
          source.existsSync() &&
          source.lengthSync() > 0) {
        destination.parent.createSync(recursive: true);
        source.copySync(destination.path);
      }
    } on FileSystemException {
      // Validation below reports an unwritable/incomplete SDK as unavailable.
    }
    return isValidBundle(candidate) ? DarwinSdk(candidate) : null;
  }

  /// A complete bundle has Swift artifact metadata and a usable iPhoneOS SDK.
  static bool isValidBundle(String candidate) {
    if (!File(p.join(candidate, 'info.json')).existsSync() ||
        !File(p.join(candidate, 'swift-sdk.json')).existsSync() ||
        !File(p.join(candidate, 'toolset.json')).existsSync()) {
      return false;
    }

    final sdk = _firstSdk(_sdksDir(candidate, 'iPhoneOS'), 'iPhoneOS');
    final swiftResources = p.join(
      candidate,
      'Developer',
      'Toolchains',
      'XcodeDefault.xctoolchain',
      'usr',
      'lib',
      'swift',
      'iphoneos',
    );
    final canonicalLayout = _canonicalLayout(candidate);
    final runtimeLayout = _runtimeLayout(candidate);
    return sdk != null &&
        Directory(
          p.join(sdk, 'System', 'Library', 'Frameworks'),
        ).existsSync() &&
        Directory(swiftResources).existsSync() &&
        canonicalLayout.existsSync() &&
        canonicalLayout.lengthSync() > 0 &&
        runtimeLayout.existsSync() &&
        runtimeLayout.lengthSync() > 0;
  }

  /// First versioned iPhoneOSXX.X.sdk found, else first iPhoneOS.sdk.
  String iPhoneOSSdk() {
    final dir = _sdksDir(bundle, 'iPhoneOS');
    final pick = _firstSdk(dir, 'iPhoneOS');
    if (pick == null) {
      throw DarwinSdkError(
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

  static File _canonicalLayout(String bundle) => File(
    p.join(
      bundle,
      'Developer',
      'Toolchains',
      'XcodeDefault.xctoolchain',
      'usr',
      'lib',
      'swift',
      'iphoneos',
      'layouts-arm64.yaml',
    ),
  );

  static File _runtimeLayout(String bundle) => File(
    p.join(
      bundle,
      'Developer',
      'Runtimes',
      'XcodeDefault.xctoolchain',
      'usr',
      'bin',
      'layouts-arm64.yaml',
    ),
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
///
/// swiftly's proxy shims are skipped. The lld inside a Swift toolchain is a
/// downstream build that refuses iOS device targets ("This version of lld does
/// not support linking for platform iOS"), and its shim cannot even be spawned
/// from a clang that swiftly itself proxied ("Circular swiftly proxy
/// invocation"). Only the stock LLVM `ld64.lld` can link the Mach-O output.
Future<String> resolveLd64Lld(DarwinSdk _) async =>
    await ProcessRunner.which('ld64.lld', accept: usableLd64Lld) ??
    (throw DarwinSdkError(
      "No usable 'ld64.lld' on PATH.\n"
      "swiftly's bundled lld cannot link for iOS, so it is skipped. Install "
      'the LLVM one — `xcross setup`, or `sudo apt install lld` on Linux — '
      'and make sure it is on PATH.',
    ));

/// PATH filter for [resolveLd64Lld] and the `xcross setup` requirement check.
bool usableLd64Lld(String path) => !ProcessRunner.isSwiftlyProxy(path);
