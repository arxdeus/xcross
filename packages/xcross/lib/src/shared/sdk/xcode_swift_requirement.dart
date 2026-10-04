import 'package:path/path.dart' as p;

/// The Swift release each Xcode generation's Darwin SDK needs.
///
/// Xcode 27's SDK ships `.swiftinterface` files and text stubs written in a
/// dialect older compilers reject, so a bundle extracted from it is unusable
/// with Swift 6.3 or earlier: the failure surfaces much later as a parse
/// error inside a system module, which is nearly impossible to trace back to
/// the toolchain. Keyed by Xcode major version, lowest supported Swift first.
const _minimumSwiftForXcode = <int, (int, int)>{27: (6, 4)};

/// Matches the `Swift version 6.4` fragment in any of the version lines the
/// toolchain binaries print (`swift`, `swift-frontend`, vendor clang builds
/// such as "Apple Swift version 6.4 (swiftlang-…)").
final _swiftVersionPattern = RegExp(r'Swift version (\d+)\.(\d+)');

/// Matches a two-or-more-digit major version in an SDK directory name
/// (`iPhoneOS27.0.sdk`) or an Xcode archive name (`Xcode_27.0_beta.xip`).
final _versionedNamePattern = RegExp(r'(\d+)(?:\.(\d+))?');

/// Guards the pairing of a Darwin SDK generation with the host Swift.
///
/// `sdk install` checks it twice: once from the archive's file name, before
/// the hours-long extraction, and once from the extracted SDK, which is the
/// authoritative answer. `doctor` checks an already-installed bundle, so a
/// host that downgraded Swift after installing still hears about it.
abstract final class XcodeSwiftRequirement {
  /// The lowest Swift version usable with an Xcode [major] generation's SDK,
  /// or null when that generation carries no requirement.
  static (int, int)? minimumSwift(int major) => _minimumSwiftForXcode[major];

  /// `(6, 4)` from any line containing `Swift version 6.4`, else null.
  static (int, int)? parseSwiftVersion(String versionOutput) {
    final match = _swiftVersionPattern.firstMatch(versionOutput);
    if (match == null) return null;
    return (int.parse(match.group(1)!), int.parse(match.group(2)!));
  }

  /// Xcode generation from an iPhoneOS SDK path: `iPhoneOS27.0.sdk` → 27.
  ///
  /// The iOS SDK major version and the Xcode major version have matched since
  /// Xcode 26, which is the first release this table knows about. An
  /// unversioned `iPhoneOS.sdk` yields null.
  static int? xcodeMajorFromSdkPath(String sdkPath) =>
      _major(p.basename(sdkPath), 'iPhoneOS');

  /// Xcode generation from an archive name: `Xcode_27.0_beta.xip` → 27.
  ///
  /// Only a hint: users rename downloads freely, so null here means "cannot
  /// tell", never "no requirement".
  static int? xcodeMajorFromXipPath(String xipPath) =>
      _major(p.basename(xipPath), 'Xcode');

  /// The number following [prefix] in [name], ignoring separators.
  static int? _major(String name, String prefix) {
    if (!name.toLowerCase().startsWith(prefix.toLowerCase())) return null;
    var rest = name.substring(prefix.length);
    while (rest.isNotEmpty && (rest[0] == '_' || rest[0] == '-')) {
      rest = rest.substring(1);
    }
    final match = _versionedNamePattern.matchAsPrefix(rest);
    if (match == null) return null;
    return int.parse(match.group(1)!);
  }

  /// Why [swiftVersionOutput] cannot build against an Xcode [xcodeMajor] SDK,
  /// or null when the pairing is fine or cannot be judged.
  ///
  /// An unreadable Swift version is never reported as a mismatch: some
  /// toolchain proxies (swiftly, mise) answer nothing at all, and blocking an
  /// install over a missing string would be worse than the diagnostic it is
  /// trying to improve.
  static String? mismatch({
    required int xcodeMajor,
    required String swiftVersionOutput,
    String? swiftPath,
  }) {
    final required = minimumSwift(xcodeMajor);
    if (required == null) return null;
    final found = parseSwiftVersion(swiftVersionOutput);
    if (found == null) return null;
    if (found.$1 > required.$1) return null;
    if (found.$1 == required.$1 && found.$2 >= required.$2) return null;
    final where = swiftPath == null ? '' : ' ($swiftPath)';
    return 'The Darwin SDK from Xcode $xcodeMajor requires Swift '
        '${required.$1}.${required.$2} or newer, but the `swift` on PATH is '
        '${found.$1}.${found.$2}$where.';
  }

  /// [mismatch] with the "install a newer Swift" advice appended.
  static String? mismatchWithHint({
    required int xcodeMajor,
    required String swiftVersionOutput,
    String? swiftPath,
    String? installHint,
  }) {
    final problem = mismatch(
      xcodeMajor: xcodeMajor,
      swiftVersionOutput: swiftVersionOutput,
      swiftPath: swiftPath,
    );
    if (problem == null) return null;
    return '$problem\n'
        '${installHint ?? 'Install a newer Swift from https://www.swift.org/install/'}';
  }
}
