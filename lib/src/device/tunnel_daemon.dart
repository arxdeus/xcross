import 'dart:async';
import 'dart:io';

import 'package:xcross/src/constants.dart';
import 'package:xcross/src/device/pymd.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';
import 'package:xcross/src/util/sudo.dart';

/// Manages the `pymobiledevice3 remote tunneld` daemon lifecycle.
///
/// * If tunneld REST API is already reachable → reuse it (no ownership taken).
/// * Otherwise → start `[sudo] pymobiledevice3 remote tunneld` as background
///   child, wait up to 40 s for it to come up.
/// * [stop] tears down only a daemon we started ourselves.
class TunnelDaemon {
  Process? _process;

  /// Whether we started the daemon. When false, [stop] leaves the user's own
  /// long-running tunneld alone instead of SIGTERMing it on exit.
  bool _ownsDaemon = false;

  /// Ensure a tunneld REST API is reachable; start one if needed.
  Future<void> ensureRunning() async {
    if (await _isReachable()) {
      logStatus('[xtool] RSD tunnel daemon already running (reusing it)');
      return;
    }

    final inv = await Pymd.resolve();
    final sudo = await Sudo.resolve();
    final usbmux = Pymd.resolvedUsbmuxAddress();

    // Cache sudo credentials interactively first, then start the long-lived
    // daemon with piped stdio (never inheritStdio — that steals `r`/`R`/`q`
    // from the hot-reload keypress loop for the whole session).
    await Sudo.cacheCredentials(
      manualHint: 'Start tunneld manually:\n'
          '    sudo pymobiledevice3 remote tunneld',
    );

    // Build: [sudo -n] [env USBMUXD_SOCKET_ADDRESS=…] <exe> … remote tunneld
    // sudo strips the env by default; without the unix socket path,
    // Linux pymobiledevice3 targets 127.0.0.1:27015 and fails under usbipd.
    // `-n` is safe here because `Sudo.cacheCredentials` just refreshed the
    // timestamp (or we are already root / passwordless).
    final argv = <String>[
      if (sudo != null) ...[sudo, '-n'],
      if (sudo != null && usbmux != null) ...[
        'env',
        'USBMUXD_SOCKET_ADDRESS=$usbmux',
      ],
      inv.executable,
      ...inv.prefixArgs,
      'remote',
      'tunneld',
    ];

    logStatus(
      '[pymobiledevice3] starting RSD tunnel daemon'
      '${sudo != null ? ' (needs root)' : ''}:\n'
      '    ${argv.join(' ')}',
    );

    final tmpDir = Platform.environment['TMPDIR'] ?? '/tmp';
    final logPath = '$tmpDir/xtool-tunneld.log';
    final logFile = File(logPath);
    if (!logFile.existsSync()) logFile.createSync(recursive: true);

    late Process proc;
    try {
      proc = await Process.start(
        argv[0],
        argv.sublist(1),
        environment: Pymd.usbmuxEnvironment(),
      );
    } catch (e) {
      throw XcrossError('could not start tunneld: $e');
    }

    // Detach from our TTY completely — daemon must not consume keypresses.
    try {
      await proc.stdin.close();
    } catch (_) {}
    final logSink = logFile.openWrite(mode: FileMode.append);
    proc.stdout.listen(logSink.add, onError: (_) {});
    proc.stderr.listen(logSink.add, onError: (_) {});
    unawaited(proc.exitCode.then((_) async {
      try {
        await logSink.flush();
        await logSink.close();
      } catch (_) {}
    }));

    _process = proc;
    _ownsDaemon = true;

    final up = await pollUntil<bool>(
      timeout: const Duration(seconds: 40),
      interval: const Duration(seconds: 1),
      attempt: () async => await _isReachable() ? true : null,
    );
    if (up ?? false) {
      logStatus('[pymobiledevice3] RSD tunnel daemon is up');
      return;
    }
    throw XcrossError(
      'tunneld did not come up. Try starting it manually in another terminal:\n'
      '    sudo pymobiledevice3 remote tunneld\n'
      'See $logPath for daemon output.',
    );
  }

  /// Tear down only the daemon WE started. Safe to call multiple times.
  void stop() {
    if (!_ownsDaemon) return;
    final proc = _process;
    _process = null;
    _ownsDaemon = false;
    if (proc == null) return;

    logStatus('[xtool] stopping RSD tunnel daemon…');

    // The daemon runs under sudo (root); escalate via sudo kill.
    Sudo.resolve().then((sudo) {
      if (sudo != null) {
        Process.run(sudo, ['kill', '-TERM', '${proc.pid}']);
      } else {
        proc.kill();
      }
    });
    // Best-effort direct signal.
    proc.kill();
  }

  Future<bool> _isReachable() async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);
      try {
        final req =
            await client.getUrl(Uri.parse(DeviceConstants.tunneldUrl));
        final resp = await req.close();
        await resp.drain<void>();
        return resp.statusCode >= 200 && resp.statusCode < 300;
      } finally {
        client.close();
      }
    } catch (_) {
      return false;
    }
  }
}
