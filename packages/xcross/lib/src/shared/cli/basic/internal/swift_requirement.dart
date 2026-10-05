import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/sdk/xcode_swift_requirement.dart';

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

  /// Throws [XcrossError] when [swift] reports a version older than the
  /// host's [minimum]. A null [minimum], or a toolchain whose version cannot
  /// be read, passes: see [XcodeSwiftRequirement].
  Future<void> requireMinimum(
    String swift,
    (int, int)? minimum, {
    required String installGuidance,
  }) async {
    if (minimum == null) return;
    final String output;
    try {
      final printed = await runner.run(swift, const ['--version']);
      output = '${printed.stdout}\n${printed.stderr}';
    } on Object catch (error) {
      runner.log.logTrace('Could not read the host Swift version: $error');
      return;
    }
    final problem = XcodeSwiftRequirement.hostFloorMismatch(
      minimum: minimum,
      swiftVersionOutput: output,
      swiftPath: swift,
      installHint: installGuidance,
    );
    if (problem != null) throw XcrossError(problem);
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
}
