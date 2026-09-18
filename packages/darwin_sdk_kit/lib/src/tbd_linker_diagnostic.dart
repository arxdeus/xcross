import 'package:darwin_sdk_kit/src/tbd_architecture_rewrite.dart';
import 'package:darwin_sdk_kit/src/tbd_bundle_patch.dart';
import 'package:path/path.dart' as p;

/// Recognises the `ld64.lld` failure that the `.tbd` rewrite exists to
/// prevent, and explains it in terms of the SDK rather than the linker.
///
/// The raw diagnostic names whichever framework happened to be read first,
/// so on its own it points at `UIKit.tbd` rather than at an SDK that needs
/// re-patching.
abstract final class TbdLinkerDiagnostic {
  /// Whether [output] failed because the linker met an unknown architecture.
  ///
  /// Both markers are required: a malformed stub can fail for reasons that
  /// have nothing to do with this rewrite, and those must keep their own
  /// error rather than be explained away by it.
  static bool reportsUnknownArchitecture(String output) =>
      output.contains(unknownArchitectureMarker) &&
      output.contains(unreadableTapiMarker);

  /// Runs [link], replacing only the unknown-architecture failure with
  /// [guidance] for [bundle]; every other failure propagates untouched.
  ///
  /// [wrap] builds the caller's own error type, so each build path keeps
  /// reporting failures in the form the rest of it already handles.
  static Future<T> explainFailures<T>(
    Future<T> Function() link, {
    required String bundle,
    required Exception Function(String message) wrap,
  }) async {
    try {
      return await link();
    } on Object catch (error) {
      if (!reportsUnknownArchitecture('$error')) rethrow;
      throw wrap('${guidance(bundle)}\n\n$error');
    }
  }

  /// What to tell a user whose link hit an unparsable stub architecture.
  static String guidance(String bundle) =>
      'The linker could not read a Darwin SDK text stub because it declares '
      'an architecture it does not know '
      '(${tbdArchitectureAliases.keys.join(', ')}, added by Xcode 27 SDKs and '
      'only understood by ld64.lld $firstLd64LldWithArm64eX1 or newer).\n'
      'xcross rewrites those stubs when it installs or resolves the SDK; '
      'delete "${p.join(bundle, TbdBundlePatch.stampName)}" and run any '
      'xcross command to redo that rewrite, or reinstall the SDK with '
      '`xcross sdk install <path-to-Xcode.xip>`.';
}
