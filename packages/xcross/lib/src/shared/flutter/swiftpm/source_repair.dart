import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/swift_package_host_patches.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';
import 'package:xcross/src/shared/sdk/sdk_install_constants.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmSourceRepair<T extends PlatformHostInterface> {
  SwiftPmSourceRepair(this.runtime);
  final SwiftPmRuntime<T> runtime;

  /// Fragments that mark a dependency fetch as a transient network failure
  /// rather than a real, reproducible error.
  ///
  /// Resolving this plugin graph pulls from a dozen GitHub repositories, and
  /// a reset or refused connection on any one of them fails the whole build
  /// even though a retry moments later succeeds.
  static const transientNetworkFailureMarkers = <String>[
    'connection was reset',
    'could not connect to server',
    'failed to connect to',
    'recv failure',
    'send failure',
    'operation timed out',
    'connection timed out',
    'empty reply from server',
    'unexpected disconnect',
    'early eof',
    'rpc failed',
    'the remote end hung up',
    'temporary failure in name resolution',
    'could not resolve host',
    'ssl_read',
    'gnutls_handshake',
    'transfer closed',
    'http/2 stream',
    'couldn\u2019t fetch updates from remote repositories',
    "couldn't fetch updates from remote repositories",
  ];

  /// Retry once, and only when the exact compiler diagnostic changed owned
  /// staged sources. Unrelated failures and failed repairs keep their errors.
  Future<void> buildWithSwiftUIStateRecovery({
    required Future<void> Function() build,
    required List<String> ownedRoots,
  }) async {
    try {
      await build();
    } on Object catch (error, stack) {
      bool changed;
      try {
        changed = await repairMissingSwiftUIStateMacro(
          error.toString(),
          ownedRoots: ownedRoots,
        );
      } on Object {
        Error.throwWithStackTrace(error, stack);
      }
      if (!changed) rethrow;
      await build();
    }
  }

  Future<bool> repairMissingSwiftUIStateMacro(
    String diagnostics, {
    required List<String> ownedRoots,
  }) async {
    final diagnostic = RegExp(
      r"^(.+\.swift):\d+:\d+: error: external macro implementation type 'SwiftUIMacros\.StateMacro' could not be found for macro 'State\([^'\r\n]*\)'; plugin for module 'SwiftUIMacros' not found\s*$",
      multiLine: true,
    );
    final paths = diagnostic
        .allMatches(diagnostics)
        .map((match) => match[1]!)
        .toSet();
    if (paths.isEmpty) return false;
    final roots = <(String, String)>[
      for (final root in ownedRoots)
        if (Directory(root).existsSync())
          (
            p.normalize(p.absolute(root)),
            Directory(root).resolveSymbolicLinksSync(),
          ),
    ];
    var changed = false;
    for (final path in paths) {
      if (!p.isAbsolute(path)) continue;
      final file = File(p.normalize(path));
      if (!file.existsSync()) continue;
      final realPath = file.resolveSymbolicLinksSync();
      if (!roots.any(
        (root) =>
            p.isWithin(root.$1, file.path) && p.isWithin(root.$2, realPath),
      )) {
        continue;
      }
      final original = await file.readAsString();
      final repaired = restoreSwiftUIStatePropertyWrapper(original);
      if (repaired == original) continue;
      await runtime.filesystem.writeStable(file.path, repaired);
      changed = true;
    }
    return changed;
  }

  Future<void> buildTranslatingSdkMismatch(
    Future<void> Function() build,
  ) async {
    try {
      await build();
    } on Object catch (error) {
      if (!'$error'.contains(swiftSdkMismatchMarker)) rethrow;
      throw FlutterBuildError(runtime.sdkIdentity.mismatchGuidance(null));
    }
  }

  /// One `swift package resolve` attempt against [directory].
  ///
  /// SwiftPM resolves source-control dependencies by spawning git, so this
  /// needs the same non-interactive settings as our own clones: otherwise a
  /// moved or private dependency parks SwiftPM on an unanswerable credential
  /// prompt.
  ///
  /// Deliberately unbounded. A cold graph the size of firebase-ios-sdk is
  /// legitimately slow, and a wall-clock cap turned a slow build into a
  /// failed one. The non-interactive git settings in
  /// [swiftProcessEnvironment] are what keep a credential prompt from
  /// hanging forever, not a timeout.
  Future<void> resolveOnce(String swift, String directory) async {
    final result = await runtime.runner.run(swift, [
      ...runtime.hostPolicy.packagePrefix,
      ...runtime.processPolicy.hostManifestArguments(),
      '--package-path',
      directory,
      'resolve',
    ], environment: runtime.processPolicy.swiftProcessEnvironment());
    if (result.exitCode != 0) {
      throw FlutterBuildError(
        'Cannot resolve SwiftPM dependencies in $directory:\n'
        '${SwiftPmSourceRepair.resolveDiagnostics(result)}',
      );
    }
  }

  /// Both output streams of a failed resolve, in that order.
  ///
  /// SwiftPM reports fetch progress on stderr but writes the diagnostic that
  /// explains a failure to stdout, so reporting stderr alone produced CI logs
  /// that ended on a successful "Computed ..." line with no stated reason.
  /// The combined text is also what [isTransientNetworkFailure] matches on,
  /// so a reset that SwiftPM reports on stdout is still retried.
  static String resolveDiagnostics(CapturedProcess result) => [
    result.stdout.trim(),
    result.stderr.trim(),
  ].where((stream) => stream.isNotEmpty).join('\n');
}
