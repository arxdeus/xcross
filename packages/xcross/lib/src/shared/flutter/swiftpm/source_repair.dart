import 'dart:async';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';
import 'package:xcross/src/shared/sdk/sdk_install_constants.dart';

@internal
const String flutterFrameworkPackageName = 'FlutterFramework';
@internal
const String pluginsProductName = 'FlutterPluginsGenerated';

@internal
final class SwiftPmSourceRepair<T extends PlatformHostInterface> {
  SwiftPmSourceRepair({
    required this.filesystem,
    required this.hostPolicy,
    required this.processPolicy,
    required this.runner,
    required this.sdkIdentity,
  });
  final SwiftPmFilesystem<T> filesystem;
  final SwiftPmHostPolicy hostPolicy;
  final SwiftPmProcessPolicy<T> processPolicy;
  final ProcessRunner<T> runner;
  final SwiftPmSdkIdentity sdkIdentity;

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
    'ssl_error_syscall',
    'nsurlerrordomain code=-1001 ',
    'nsurlerrordomain code=-1004 ',
    'nsurlerrordomain code=-1005 ',
    'gnutls_handshake',
    'transfer closed',
    'http/2 stream',
    'couldn\u2019t fetch updates from remote repositories',
    "couldn't fetch updates from remote repositories",
  ];

  Future<void> buildTranslatingSdkMismatch(
    Future<void> Function() build,
  ) async {
    try {
      await build();
    } on Object catch (error) {
      if (!'$error'.contains(swiftSdkMismatchMarker)) rethrow;
      throw FlutterBuildError(sdkIdentity.mismatchGuidance(null));
    }
  }

  /// One `swift package resolve` attempt against [directory].
  ///
  /// SwiftPM resolves source-control dependencies by spawning git, so this
  /// needs non-interactive git settings: otherwise a
  /// moved or private dependency parks SwiftPM on an unanswerable credential
  /// prompt.
  ///
  /// Deliberately unbounded. A cold graph the size of firebase-ios-sdk is
  /// legitimately slow, and a wall-clock cap turned a slow build into a
  /// failed one. The non-interactive git settings in
  /// [swiftProcessEnvironment] are what keep a credential prompt from
  /// hanging forever, not a timeout.
  Future<void> resolveOnce(String swift, String directory) async {
    runner.log.logTrace('[swift package resolve] running in $directory');
    final result = await runner.run(swift, [
      ...hostPolicy.packagePrefix,
      ...processPolicy.hostManifestArguments(),
      '--package-path',
      directory,
      'resolve',
    ], environment: await processPolicy.swiftProcessEnvironment());
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
