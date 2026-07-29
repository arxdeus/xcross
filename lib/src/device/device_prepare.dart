import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xcross/src/device/pymd.dart';
import 'package:xcross/src/device/tunnel_daemon.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';
import 'package:xcross/src/util/sudo.dart';

/// One-shot iOS 17+ host prep: mount the Developer Disk Image and start the
/// RSD tunnel(s) that [CoreDeviceLauncher] needs.
///
/// Equivalent to the manual:
/// ```sh
/// sudo pymobiledevice3 mounter auto-mount
/// sudo pymobiledevice3 lockdown start-tunnel
/// ```
/// plus ensuring `remote tunneld` is up (the REST discovery path used by
/// `xcross flutter run`).
abstract final class DevicePrepare {
  static final _tunnelReadyPattern = RegExp(
    'tunnel created|RSD Address|RSD Port',
    caseSensitive: false,
  );

  /// Mount DDI, ensure tunneld, and start a lockdown RSD tunnel in the
  /// background. Leaves long-lived processes running after return.
  static Future<void> prepare() async {
    if (!await Pymd.ensureInstalled()) {
      throw XcrossError(
        'pymobiledevice3 is required but could not be installed automatically.',
      );
    }

    await Sudo.cacheCredentials(
      manualHint: 'Start prepare steps manually:\n'
          '    sudo pymobiledevice3 mounter auto-mount\n'
          '    sudo pymobiledevice3 lockdown start-tunnel',
    );

    await _autoMount();
    await TunnelDaemon().ensureRunning();
    await _ensureLockdownTunnel();

    logStatus(
      '[xcross] prepare done — DDI mounted, tunneld up, lockdown tunnel '
      'running.\n'
      '    You can now: xcross flutter run -u <UDID>',
    );
  }

  /// `sudo pymobiledevice3 mounter auto-mount` (one-shot).
  static Future<void> _autoMount() async {
    final argv = await _elevatedPymdArgs(['mounter', 'auto-mount']);
    logStatus(
      '[pymobiledevice3] mounting Developer Disk Image:\n'
      '    ${argv.join(' ')}',
    );
    final proc = await Process.start(
      argv.first,
      argv.sublist(1),
      environment: Pymd.usbmuxEnvironment(),
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await proc.exitCode;
    if (code != 0) {
      throw XcrossError(
        'mounter auto-mount failed (exit $code).\n'
        'Retry manually:\n'
        '    sudo pymobiledevice3 mounter auto-mount',
      );
    }
    logStatus('[pymobiledevice3] Developer Disk Image mounted ✓');
  }

  /// Start `lockdown start-tunnel` in the background if one is not already
  /// producing an RSD tunnel. Leaves the process running after prepare exits.
  static Future<void> _ensureLockdownTunnel() async {
    if (await _lockdownTunnelLooksAlive()) {
      logStatus('[pymobiledevice3] lockdown start-tunnel already running');
      return;
    }

    final argv = await _elevatedPymdArgs(['lockdown', 'start-tunnel']);
    final tmpDir = Platform.environment['TMPDIR'] ?? '/tmp';
    final logPath = '$tmpDir/xcross-start-tunnel.log';
    final logFile = File(logPath);
    if (!logFile.existsSync()) logFile.createSync(recursive: true);

    logStatus(
      '[pymobiledevice3] starting lockdown RSD tunnel'
      ' (background; log: $logPath):\n'
      '    ${argv.join(' ')}',
    );

    late Process proc;
    try {
      // Piped (never inheritStdio): an inherited stdin steals `r`/`R`/`q` from
      // the hot-reload keypress loop for the whole session.
      proc = await Process.start(
        argv.first,
        argv.sublist(1),
        environment: Pymd.usbmuxEnvironment(),
      );
    } catch (e) {
      throw XcrossError('could not start lockdown start-tunnel: $e');
    }

    try {
      await proc.stdin.close();
    } catch (_) {}

    final logSink = logFile.openWrite(mode: FileMode.append);
    final ready = Completer<void>();

    void onLine(String line) {
      final trimmed = line.trimRight();
      if (trimmed.isEmpty) return;
      logStatus(trimmed);
      if (!ready.isCompleted && _tunnelReadyPattern.hasMatch(trimmed)) {
        ready.complete();
      }
    }

    // Tee the raw bytes to the log file, then decode a separate view of the
    // same broadcast stream into lines for the readiness match.
    for (final raw in [proc.stdout, proc.stderr]) {
      final stream = raw.asBroadcastStream();
      stream.listen(logSink.add, onError: (_) {});
      stream
          // Lossy on purpose: pymobiledevice3 can emit non-UTF-8 bytes, and a
          // strict decoder would drop the whole chunk — losing the ASCII
          // readiness line with it and stalling until the timeout below.
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(onLine, onError: (_) {});
    }
    unawaited(proc.exitCode.then((code) async {
      try {
        await logSink.flush();
        await logSink.close();
      } catch (_) {}
      if (!ready.isCompleted) {
        ready.completeError(
          XcrossError(
            'lockdown start-tunnel exited early (code $code). '
            'See $logPath',
          ),
        );
      }
    }));

    try {
      await ready.future.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw XcrossError(
        'lockdown start-tunnel did not report a tunnel within 60s.\n'
        'Keep the phone unlocked and trusted, then retry:\n'
        '    sudo pymobiledevice3 lockdown start-tunnel\n'
        'See $logPath for output.',
      );
    } on XcrossError {
      rethrow;
    }

    logStatus(
      '[pymobiledevice3] lockdown RSD tunnel is up '
      '(pid ${proc.pid}; leave it running)',
    );
  }

  /// Best-effort: a live `start-tunnel` child usually holds a tun interface
  /// and shows up in the process list.
  static Future<bool> _lockdownTunnelLooksAlive() async {
    try {
      final result = await ProcessRunner.run('pgrep', [
        '-f',
        'pymobiledevice3.*lockdown.*start-tunnel',
      ]);
      return result.exitCode == 0 && result.stdout.trim().isNotEmpty;
    } on Object {
      return false;
    }
  }

  /// `[sudo -n] [env USBMUXD_SOCKET_ADDRESS=…] <pymd> …args`.
  static Future<List<String>> _elevatedPymdArgs(List<String> pymdArgs) async {
    final inv = await Pymd.resolve();
    final sudo = await Sudo.resolve();
    final usbmux = Pymd.resolvedUsbmuxAddress();
    return <String>[
      if (sudo != null) ...[sudo, '-n'],
      if (sudo != null && usbmux != null) ...[
        'env',
        'USBMUXD_SOCKET_ADDRESS=$usbmux',
      ],
      inv.executable,
      ...inv.prefixArgs,
      ...pymdArgs,
    ];
  }
}
