import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/src/tbd_architecture_rewrite.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Outcome of rewriting the `.tbd` files under one bundle.
@immutable
final class TbdPatchResult {
  const TbdPatchResult({required this.patched, required this.failed});

  static const none = TbdPatchResult(patched: 0, failed: 0);

  /// Stubs rewritten successfully.
  final int patched;

  /// Stubs that needed a rewrite but could not be written.
  final int failed;

  /// Whether every stub that needed rewriting got it.
  bool get complete => failed == 0;
}

/// Applies [TbdArchitectureRewrite] to the `.tbd` files of an installed SDK
/// bundle, and records that it did.
///
/// The stamp is what keeps this affordable: every resolve of an installed SDK
/// passes through [ensureApplied], and a stamped bundle costs one small file
/// read instead of a walk over tens of megabytes of text stubs.
abstract final class TbdBundlePatch {
  /// Records that a bundle's stubs were rewritten, so the scan runs once.
  static const stampName = 'xcross-tbd-targets.json';

  /// Bumping this re-runs the rewrite over an already-stamped bundle.
  static const patchVersion = 1;

  /// Whether [path] names a Mach-O text stub.
  static bool isTbdName(String path) =>
      p.extension(path).toLowerCase() == '.tbd';

  /// [bytes] with every unparsable architecture renamed, or null when there
  /// is nothing to rewrite.
  ///
  /// Decoded as latin1: `.tbd` files are ASCII, and a 1:1 byte mapping can
  /// neither throw on nor mangle a stub that is not.
  static Uint8List? rewriteBytes(Uint8List bytes) {
    final rewritten = TbdArchitectureRewrite.apply(
      latin1.decode(bytes, allowInvalid: true),
    );
    return rewritten == null ? null : latin1.encode(rewritten);
  }

  /// Rewrite [bundle] unless it is already stamped; returns stubs changed.
  ///
  /// Bundles installed by an older xcross have no stamp and are repaired in
  /// place — a few hundred milliseconds once, against the multi-gigabyte
  /// reinstall that would otherwise be the only way out.
  ///
  /// A bundle whose stubs could not all be written is left unstamped, so a
  /// later run with the permissions to fix it tries again instead of
  /// trusting a repair that did not happen.
  static int ensureApplied(String bundle) {
    if (isStamped(bundle)) return 0;
    final result = apply(bundle);
    if (result.complete) {
      stamp(bundle, files: result.patched);
    } else {
      Log.logWarn(
        'Could not rewrite ${result.failed} Darwin SDK text stub(s) under '
        '$bundle. Linking may fail with "$unknownArchitectureMarker".',
      );
    }
    if (result.patched > 0) {
      Log.logTrace(
        'TbdBundlePatch: renamed ${tbdArchitectureAliases.keys.join(', ')} in '
        '${result.patched} .tbd files under $bundle',
      );
    }
    return result.patched;
  }

  /// Rewrite every `.tbd` under [bundle] in place, whatever the stamp says.
  static TbdPatchResult apply(String bundle) {
    final root = Directory(HostPaths.long(bundle));
    if (!root.existsSync()) return TbdPatchResult.none;

    var patched = 0;
    var failed = 0;
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !isTbdName(entity.path)) continue;
      switch (_rewriteFile(entity)) {
        case _FileOutcome.rewritten:
          patched++;
        case _FileOutcome.failed:
          failed++;
        case _FileOutcome.unchanged:
          break;
      }
    }
    return TbdPatchResult(patched: patched, failed: failed);
  }

  static _FileOutcome _rewriteFile(File stub) {
    try {
      final rewritten = rewriteBytes(stub.readAsBytesSync());
      if (rewritten == null) return _FileOutcome.unchanged;
      stub.writeAsBytesSync(rewritten, flush: true);
      return _FileOutcome.rewritten;
    } on FileSystemException catch (error) {
      // A stub that cannot be rewritten is the one that will fail the link,
      // so it is counted rather than ignored: the bundle must not be stamped
      // as done while it still carries an unreadable target.
      Log.logTrace('TbdBundlePatch: could not rewrite ${stub.path}: $error');
      return _FileOutcome.failed;
    }
  }

  /// Whether [bundle] already carries a stamp for [patchVersion].
  static bool isStamped(String bundle) {
    final stamp = File(HostPaths.long(p.join(bundle, stampName)));
    if (!stamp.existsSync()) return false;
    try {
      final decoded = jsonDecode(stamp.readAsStringSync());
      if (decoded is! Map) return false;
      final version = decoded['patchVersion'];
      return version is int && version >= patchVersion;
    } on Object catch (error) {
      // An unreadable stamp is treated as absent: rewriting again is cheap
      // and idempotent, while trusting it is not.
      Log.logTrace('TbdBundlePatch: unreadable stamp at ${stamp.path}: $error');
      return false;
    }
  }

  /// Record that [bundle]'s stubs carry [patchVersion] of the rewrite.
  static void stamp(String bundle, {required int files}) {
    const encoder = JsonEncoder.withIndent('  ');
    final contents = encoder.convert({
      'patchVersion': patchVersion,
      'renamedArchitectures': tbdArchitectureAliases,
      'files': files,
    });
    final stamp = File(HostPaths.long(p.join(bundle, stampName)));
    try {
      stamp.writeAsStringSync('$contents\n');
    } on FileSystemException catch (error) {
      // Only costs a rescan next time, so it is not worth failing an install
      // or a build over.
      Log.logTrace('TbdBundlePatch: could not stamp $bundle: $error');
    }
  }
}

enum _FileOutcome { rewritten, unchanged, failed }
