import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/errors/errors.dart';

/// Where each host installs the Swift toolchain, for the "install it first"
/// message. Linux gets swiftly because that is what swift.org now recommends
/// and what the SDK-install step has to read a version out of.
const _swiftInstallHint = {
  'windows':
      'Install Swift for Windows from https://www.swift.org/install/windows/\n'
      'then open a new terminal so its bin directory is on PATH.',
  'macos':
      'Install Swift with Xcode or the toolchain installer from\n'
      'https://www.swift.org/install/macos/',
  'linux':
      'Install Swift from https://www.swift.org/install/linux/ (swiftly is the\n'
      'easiest route), then open a new terminal so its bin directory is on '
      'PATH.',
};

/// Preflight for the two commands that cannot do anything useful without a
/// Swift toolchain already on PATH.
///
/// `xcross setup` never installs Swift on any host — it is manual everywhere,
/// and the distro packages it does install are only Swift's *dependencies*.
/// `xcross sdk install` is stricter still: it patches the Darwin SDK bundle
/// with the selected toolchain's clang builtin headers and stamps that
/// toolchain's identity into the bundle, so without Swift it cannot produce a
/// usable SDK at all. Failing here, before an hours-long extraction or a
/// package-manager transaction, is far cheaper than failing after.
@internal
final class SwiftRequirement {
  const SwiftRequirement(this.runner);

  final ProcessRunner runner;

  PlatformHostInterface get host => runner.host;

  /// Throws [XcrossError] unless a usable `swift` is on PATH.
  ///
  /// [action] completes the sentence "xcross cannot <action> …".
  Future<String> require(
    String action, {
    required String installGuidance,
    String? extra,
  }) async {
    final swift = await runner.which(runner.hostExecutableName('swift'));
    if (swift == null) {
      throw XcrossError(
        'No Swift toolchain found on PATH, so xcross cannot $action.\n'
        '$installGuidance\n'
        'Verify it with:\n'
        '    swift --version'
        '${extra == null ? '' : '\n\n$extra'}',
      );
    }
    return swift;
  }

  /// The clang that must sit beside the selected `swift`.
  ///
  /// A Swift installation missing its own clang cannot supply the builtin
  /// headers the Darwin SDK bundle is patched with, and the failure would
  /// otherwise surface much later as unresolved `import UIKit`.
  Future<void> requireSiblingClang(String swift) async {
    final String resolved;
    try {
      resolved = await host.fileSystem.file(swift).resolveSymbolicLinks();
    } on Object {
      // An unresolvable path is the installer's problem to report, not a
      // reason to block here; sdk_install surfaces it with full detail.
      return;
    }
    final clang = host.paths.context.join(
      host.paths.context.dirname(resolved),
      host.paths.executableName('clang'),
    );
    if (host.fileSystem.file(clang).existsSync()) return;
    throw XcrossError(
      'The Swift toolchain at "$resolved" ships no sibling clang '
      '("$clang").\n'
      'xcross needs it to patch the Darwin SDK with builtin headers matching '
      'this Swift.\n'
      'Reinstall a complete Swift toolchain from https://www.swift.org/install/',
    );
  }

  /// Per-host instructions for installing Swift.
  static String installHint(String name) {
    return _swiftInstallHint[name] ??
        'Install Swift from https://www.swift.org/install/ and ensure its bin '
            'directory is on PATH.';
  }
}
