import 'dart:async';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_repair.dart';

@internal
const String flutterFrameworkPackageName = 'FlutterFramework';
@internal
const String pluginsProductName = 'FlutterPluginsGenerated';

@internal
final class SwiftPmNetworkRetry<T extends PlatformHostInterface> {
  SwiftPmNetworkRetry({required this.runner});
  final ProcessRunner<T> runner;
  static bool isTransientNetworkFailure(Object error) {
    final text = error.toString().toLowerCase();
    // Our own timeout already waited the full budget; retrying it would
    // multiply the very stall the timeout exists to cut short.
    if (text.contains('and was killed')) return false;
    return SwiftPmSourceRepair.transientNetworkFailureMarkers.any(
      text.contains,
    );
  }

  /// Windows crash statuses `swift-package.exe` dies with intermittently
  /// while resolving a large plugin graph, after every checkout already
  /// succeeded. The same resolve on the same machine passes when re-run, and
  /// resolving is idempotent, so these are retried like a network blip.
  static const transientCrashMarkers = <String>[
    'status_access_violation',
    'status_heap_corruption',
  ];

  /// Whether a failed `swift package resolve` is worth another attempt:
  /// either a transient network failure or a nondeterministic SwiftPM crash.
  static bool isTransientResolveFailure(Object error) {
    if (isTransientNetworkFailure(error)) return true;
    final text = error.toString().toLowerCase();
    if (text.contains('and was killed')) return false;
    return transientCrashMarkers.any(text.contains);
  }

  /// Runs [action], retrying while it fails for an apparently transient
  /// reason, as decided by [retryable] (network failures by default).
  ///
  /// Anything else propagates on the first attempt, so a genuine build error
  /// still fails fast instead of being retried three times.
  Future<void> retryingTransientNetworkFailure(
    Future<void> Function() action, {
    required String label,
    int attempts = 3,
    Duration backoff = const Duration(seconds: 5),
    Future<void> Function(Duration)? delay,
    bool Function(Object error) retryable = isTransientNetworkFailure,
  }) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await action();
      } on Object catch (error) {
        if (attempt >= attempts || !retryable(error)) {
          rethrow;
        }
        final pause = backoff * attempt;
        runner.log.logTrace(
          '$label failed on a transient error '
          '(attempt $attempt of $attempts), retrying in '
          '${pause.inSeconds}s: $error',
        );
        await (delay ?? Future<void>.delayed)(pause);
      }
    }
  }
}
