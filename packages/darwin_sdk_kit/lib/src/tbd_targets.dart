import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Outcome of rewriting the `.tbd` files under one bundle.
@immutable
final class TbdPatchResult {
  const TbdPatchResult({required this.patched, required this.failed});

  /// Stubs rewritten successfully.
  final int patched;

  /// Stubs that needed a rewrite but could not be written.
  final int failed;

  /// Whether every stub that needed rewriting got it.
  bool get complete => failed == 0;
}

/// Rewrites Mach-O text stubs (`.tbd`) so an `ld64.lld` that predates a CPU
/// subtype can still read the SDK that declares it.
///
/// Xcode 27 SDKs added the `arm64e.x1` subtype (`CPU_SUBTYPE_ARM64E_X1`, 12)
/// and list it beside `arm64e` in every stub:
///
/// ```yaml
/// targets: [ arm64e-ios, arm64e.x1-ios ]
/// ```
///
/// LLVM only learned that name in `llvm/TextAPI/Architecture.def` with
/// llvm/llvm-project#222721 (merged into `main`; the `release/23.x` backport,
/// llvm/llvm-project#224185, is still open), so every released linker rejects
/// the whole document:
///
/// ```text
/// ld64.lld: error: could not load TAPI file at .../UIKit.tbd: malformed file
/// .../UIKit.tbd:3:32: error: unknown architecture
/// targets: [ arm64e-ios, arm64e.x1-ios ]
///                        ^~~~~~~~~~~~~~
/// ```
///
/// The unknown slice is *renamed* to `arm64e` rather than deleted. Deleting
/// can empty a `targets:` list, and a stub whose top-level list is empty
/// fails differently and just as fatally ("is incompatible with arm64"),
/// while a duplicate target is something the reader already tolerates
/// everywhere it accepts a target list — top-level, `exports`, `re-exports`,
/// `reexported-libraries`, `allowable-clients`, `parent-umbrella` and
/// `uuids`. Renaming is also a plain token substitution, so it costs a single
/// pass instead of list surgery.
abstract final class TbdTargets {
  /// Architecture tokens no released `ld64.lld` can parse, mapped to the
  /// ABI-compatible one it does know.
  static const architectureAliases = {'arm64e.x1': 'arm64e'};

  /// Records that a bundle's stubs were rewritten, so the scan runs once.
  static const stampName = 'xcross-tbd-targets.json';

  /// Bumping this re-runs the rewrite over an already-stamped bundle.
  static const patchVersion = 1;

  /// What `ld64.lld` prints when it meets an architecture it does not know.
  static const unknownArchitectureMarker = 'unknown architecture';

  /// What `ld64.lld` prints around [unknownArchitectureMarker].
  static const unreadableTapiMarker = 'could not load TAPI file';

  /// A token is only replaced when nothing identifier-like precedes it, so a
  /// symbol that happens to end in the same characters is left alone.
  static final RegExp _token = RegExp(
    r'(?<![A-Za-z0-9_.$])(' +
        architectureAliases.keys.map(RegExp.escape).join('|') +
        r')\b',
  );

  static bool isTbdName(String path) =>
      p.extension(path).toLowerCase() == '.tbd';

  /// [bytes] with every unparsable architecture renamed, or null when there
  /// is nothing to rewrite.
  ///
  /// Decoded as latin1: `.tbd` files are ASCII, and a 1:1 byte mapping can
  /// neither throw on nor mangle a stub that is not.
  static Uint8List? rewriteBytes(Uint8List bytes) {
    final rewritten = rewriteText(latin1.decode(bytes, allowInvalid: true));
    return rewritten == null ? null : latin1.encode(rewritten);
  }

  /// [text] with every unparsable architecture renamed, or null when there is
  /// nothing to rewrite.
  ///
  /// The plain substring test comes first because it is what almost every
  /// stub answers with: only an SDK new enough to carry the subtype has
  /// anything to rewrite, and the regex never runs for the rest.
  static String? rewriteText(String text) {
    if (!architectureAliases.keys.any(text.contains)) return null;
    final rewritten = text.replaceAllMapped(
      _token,
      (match) => architectureAliases[match.group(1)]!,
    );
    return rewritten == text ? null : rewritten;
  }

  /// Rewrite every `.tbd` under [bundle] in place.
  static TbdPatchResult patchBundle(String bundle) {
    final root = Directory(_ioPath(bundle));
    if (!root.existsSync()) {
      return const TbdPatchResult(patched: 0, failed: 0);
    }
    var patched = 0;
    var failed = 0;
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !isTbdName(entity.path)) continue;
      try {
        final bytes = entity.readAsBytesSync();
        final rewritten = rewriteBytes(bytes);
        if (rewritten == null) continue;
        entity.writeAsBytesSync(rewritten, flush: true);
        patched++;
      } on FileSystemException catch (error) {
        // A stub that cannot be rewritten is the one that will fail the
        // link, so it is counted rather than ignored: the bundle must not
        // be stamped as done while it still carries an unreadable target.
        Log.logTrace('TbdTargets: could not rewrite ${entity.path}: $error');
        failed++;
      }
    }
    return TbdPatchResult(patched: patched, failed: failed);
  }

  /// Whether [bundle] already carries a stamp for [patchVersion].
  static bool bundlePatched(String bundle) {
    final stamp = File(_ioPath(p.join(bundle, stampName)));
    if (!stamp.existsSync()) return false;
    try {
      final decoded = jsonDecode(stamp.readAsStringSync());
      if (decoded is! Map) return false;
      final version = decoded['patchVersion'];
      return version is int && version >= patchVersion;
    } on Object catch (error) {
      Log.logTrace('TbdTargets: unreadable stamp at ${stamp.path}: $error');
      return false;
    }
  }

  /// Record that [bundle]'s stubs carry [patchVersion] of the rewrite.
  static void writeStamp(String bundle, {required int files}) {
    final stamp = File(_ioPath(p.join(bundle, stampName)));
    try {
      stamp.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert({'patchVersion': patchVersion, 'renamedArchitectures': architectureAliases, 'files': files})}\n',
      );
    } on FileSystemException catch (error) {
      Log.logTrace('TbdTargets: could not stamp $bundle: $error');
    }
  }

  /// Patch [bundle] unless it is already stamped; returns the files changed.
  ///
  /// The stamp is what keeps this cheap: every resolve of an installed SDK
  /// calls through here, and a stamped bundle costs one small file read.
  /// Bundles installed by an older xcross have no stamp and are repaired in
  /// place — a few hundred milliseconds once, against the multi-gigabyte
  /// reinstall that would otherwise be the only way out.
  ///
  /// A bundle whose stubs could not all be written is left unstamped, so a
  /// later run with the permissions to fix it will try again instead of
  /// trusting a repair that did not happen.
  static int ensureBundlePatched(String bundle) {
    if (bundlePatched(bundle)) return 0;
    final result = patchBundle(bundle);
    if (result.complete) {
      writeStamp(bundle, files: result.patched);
    } else {
      Log.logWarn(
        'Could not rewrite ${result.failed} Darwin SDK text stub(s) under '
        '$bundle. Linking may fail with "$unknownArchitectureMarker".',
      );
    }
    if (result.patched > 0) {
      Log.logTrace(
        'TbdTargets: renamed ${architectureAliases.keys.join(', ')} in '
        '${result.patched} .tbd files under $bundle',
      );
    }
    return result.patched;
  }

  /// Whether [output] failed because the linker met an unknown architecture.
  static bool reportsUnknownArchitecture(String output) =>
      output.contains(unknownArchitectureMarker) &&
      output.contains(unreadableTapiMarker);

  /// What to tell a user whose link hit an unparsable stub architecture.
  static String unknownArchitectureGuidance(String bundle) =>
      'The linker could not read a Darwin SDK text stub because it declares '
      'an architecture it does not know '
      '(${architectureAliases.keys.join(', ')}, added by Xcode 27 SDKs and '
      'only understood by ld64.lld '
      '$firstLd64LldWithArm64eX1 or newer).\n'
      'xcross rewrites those stubs when it installs or resolves the SDK; '
      'delete "${p.join(bundle, stampName)}" and run any xcross command to '
      'redo that rewrite, or reinstall the SDK with '
      '`xcross sdk install <path-to-Xcode.xip>`.';

  /// First `ld64.lld` release that parses `arm64e.x1` in a `.tbd`.
  ///
  /// llvm/llvm-project#222721 landed on `main` after the 23.x branch, and its
  /// backport (llvm/llvm-project#224185) has not been merged, so no released
  /// linker has it yet and 24 is the first that will.
  static const int firstLd64LldWithArm64eX1 = 24;

  /// Win32 path form for the long paths an artifact bundle can reach.
  static String _ioPath(String path) {
    if (!Platform.isWindows) return path;
    final absolute = p.absolute(path);
    if (absolute.startsWith(r'\\?\')) return absolute;
    if (absolute.startsWith(r'\\')) {
      return '\\\\?\\UNC\\${absolute.substring(2)}';
    }
    return '\\\\?\\$absolute';
  }
}
