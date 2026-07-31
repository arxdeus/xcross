import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/process.dart';

/// Locates an installed xtool Darwin SDK on the local machine and exposes path
/// accessors for the parts needed to drive clang/ld invocations directly
/// (without `xcrun`).
class DarwinSdk {
  /// Bundle root, e.g. `~/.swiftpm/swift-sdks/darwin.artifactbundle`.
  final String bundle;

  static final RegExp _digitPattern = RegExp('[0-9]');

  DarwinSdk(this.bundle);

  /// All locations xtool may install the Darwin SDK into. First match wins.
  static List<String> _searchRoots() {
    final home = _homeDir();
    return [
      // xcross's own extraction destination (`xcross sdk install`), checked
      // first since it's the only native-Windows acquisition path.
      nativeInstallDir(),
      // SwiftPM canonical location (set by `swift sdk install`).
      p.join(home, '.swiftpm', 'swift-sdks', 'darwin.artifactbundle'),
      p.join(home, '.swiftpm', 'swift-sdks', 'darwin.xtoolsdk'),
      // macOS fallback path.
      p.join(
        home,
        'Library',
        'org.swift.swiftpm',
        'swift-sdks',
        'darwin.artifactbundle',
      ),
      p.join(
        home,
        'Library',
        'org.swift.swiftpm',
        'swift-sdks',
        'darwin.xtoolsdk',
      ),
    ];
  }

  /// Where `xcross sdk install <Xcode.xip>` extracts the iPhoneOS SDK to,
  /// and one of the roots [_searchRoots] checks.
  ///
  /// Per-user config dir convention, matching
  /// `AscCredentials.defaultConfigPath()`: `%APPDATA%` on Windows,
  /// `$XDG_CONFIG_HOME`/`~/.config` elsewhere.
  static String nativeInstallDir() =>
      p.join(_configDir(), 'xcross', 'darwin-sdk');

  /// Same per-user config dir logic as `AscCredentials._configDir()`
  /// (private there, so replicated here rather than imported).
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

  /// Resolve the SDK installed by `xtool sdk install`. Returns null if not
  /// installed.
  static DarwinSdk? current() {
    for (final candidate in _searchRoots()) {
      if (_isValidBundle(candidate)) return DarwinSdk(candidate);
    }
    return null;
  }

  /// A version marker file, or the canonical SDK sub-tree, marks a valid
  /// installed bundle.
  static bool _isValidBundle(String candidate) {
    final versionFileExists = File(
      p.join(candidate, 'darwin-sdk-version.txt'),
    ).existsSync();
    if (versionFileExists) {
      return true;
    }
    final sdksPath = p.join(
      candidate,
      'Developer',
      'Platforms',
      'iPhoneOS.platform',
      'Developer',
      'SDKs',
    );
    return Directory(sdksPath).existsSync();
  }

  /// `<bundle>/toolset/bin/ld64.lld` — Apple-compatible linker on Linux, as
  /// bundled by `xtool sdk install`. Wrong on Windows (no bundled toolset) —
  /// use [resolveLd64Lld] instead of this getter wherever the host platform
  /// matters.
  String get ld64lld => p.join(bundle, 'toolset', 'bin', 'ld64.lld');

  String _sdksDir(String platform) => p.join(
    bundle,
    'Developer',
    'Platforms',
    '$platform.platform',
    'Developer',
    'SDKs',
  );

  /// First versioned iPhoneOSXX.X.sdk found, else first .sdk under the
  /// platform. Throws [XcrossError] if missing.
  String iPhoneOSSdk() {
    final dir = _sdksDir('iPhoneOS');
    final pick = _firstSdk(dir, 'iPhoneOS');
    if (pick == null) {
      throw XcrossError(
        'DarwinSdk: Could not find iPhoneOS SDK under $dir.\n'
        "Install xtool's Darwin SDK with `xtool sdk install <Xcode.xip|Xcode.app>`.",
      );
    }
    return pick;
  }

  /// Returns the first matching `.sdk` directory under [dir] with the given
  /// [prefix], preferring versioned names (e.g. `iPhoneOS17.5.sdk`) over
  /// unversioned symlinks.
  static String? _firstSdk(String dir, String prefix) {
    final sdkDirExists = Directory(dir).existsSync();
    if (!sdkDirExists) return null;
    final entries = Directory(
      dir,
    ).listSync().map((e) => p.basename(e.path)).toList();

    final versioned = entries
        .where(
          (e) =>
              e.startsWith(prefix) &&
              e.endsWith('.sdk') &&
              e.contains(_digitPattern),
        )
        .firstOrNull;

    final pick =
        versioned ??
        entries
            .where((e) => e.startsWith(prefix) && e.endsWith('.sdk'))
            .firstOrNull;

    return pick != null ? p.join(dir, pick) : null;
  }

  static String _homeDir() =>
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '/root';
}

/// Async, platform-aware resolution of the Apple-compatible linker for
/// [sdk].
///
/// On Linux/macOS this is just [DarwinSdk.ld64lld] (xtool's bundled
/// `toolset/bin/ld64.lld`) — unchanged, zero regression. On Windows there is
/// no bundled toolset; `ld64.lld.exe` is expected to already be on PATH from
/// an LLVM install (e.g. `scoop install llvm`), so this resolves it there
/// instead. Throws [XcrossError] if not found.
Future<String> resolveLd64Lld(DarwinSdk sdk) => Platform.isWindows
    ? ProcessRunner.locateTool('ld64.lld.exe')
    : Future.value(sdk.ld64lld);
