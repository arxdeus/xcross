import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/xtool/xtool_cli.dart';

/// Pre-iOS-17 launch path. Delegates to `xtool launch`.
///
/// There is no Dart binding for the libimobiledevice debugserver, so this path
/// hands off to the `xtool` binary, which already implements it.
abstract final class DebugLauncher {
  /// Launch [bundleId] on [udid] via the legacy xtool debugserver path.
  ///
  /// The JIT Dart VM requires CS_DEBUGGED to stay set. xtool launch detaches
  /// after launch, so JIT debug apps **may** crash on detach. Use iOS 17+
  /// (CoreDeviceLauncher) for the full attached + hot-reload experience.
  static Future<void> launch({
    required String udid,
    required String bundleId,
    XtoolCli? xtool,
  }) async {
    final cli = xtool ?? XtoolCli();

    Log.logWarn(
      'Pre-iOS-17 path: xtool launch detaches immediately after launch. '
      'Flutter JIT/debug apps may crash on detach because the '
      'CS_DEBUGGED flag is dropped when the debugger disconnects.\n'
      'Recommend iOS 17+ for the full attached/hot-reload experience.',
    );

    await cli.launch(bundleId, udid: udid);
  }
}
