import 'dart:async';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_repair.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

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

  /// Runs [action], retrying while it fails for an apparently transient
  /// network reason.
  ///
  /// Anything else propagates on the first attempt, so a genuine build error
  /// still fails fast instead of being retried three times.
  Future<void> retryingTransientNetworkFailure(
    Future<void> Function() action, {
    required String label,
    int attempts = 3,
    Duration backoff = const Duration(seconds: 5),
    Future<void> Function(Duration)? delay,
  }) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await action();
      } on Object catch (error) {
        if (attempt >= attempts ||
            !SwiftPmNetworkRetry.isTransientNetworkFailure(error)) {
          rethrow;
        }
        final pause = backoff * attempt;
        runner.log.logTrace(
          '$label failed on a transient network error '
          '(attempt $attempt of $attempts), retrying in '
          '${pause.inSeconds}s: $error',
        );
        await (delay ?? Future<void>.delayed)(pause);
      }
    }
  }
}
