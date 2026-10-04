import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:dart_mobile_device/src/constants.dart';
import 'package:dart_mobile_device/src/errors.dart';
import 'package:dart_mobile_device/src/host/shared/tunnel/tunnel_process_controller.dart';
import 'package:dart_mobile_device/src/pymd/pymd.dart';

class TunnelDaemon {
  TunnelDaemon(this.pymd) : controller = TunnelProcessController(pymd.runner);

  final Pymd pymd;
  final TunnelProcessController controller;

  String get logPath => pymd.runner.host.paths.context.join(
    pymd.runner.host.paths.temporaryRoot,
    'xcross-tunneld.log',
  );

  Future<void> ensureRunning() async {
    if (await isReachable(localHttp: pymd.localHttp)) {
      pymd.runner.log.logTrace(
        'RSD tunnel daemon already running (reusing it)',
      );
      return;
    }

    await _ensureElevated();
    final sudo = await pymd.privileges.resolve();

    // Cache sudo credentials interactively first, then start the long-lived
    // daemon with piped stdio (never inheritStdio — that steals `r`/`R`/`q`
    // from the hot-reload keypress loop for the whole session).
    // Build: [sudo -n] [env USBMUXD_SOCKET_ADDRESS=…] <exe> … remote tunneld
    // sudo strips the env by default; without the unix socket path,
    // Linux pymobiledevice3 targets 127.0.0.1:27015 and fails under usbipd.
    // `-n` is safe here because `Sudo.cacheCredentials` just refreshed the
    // timestamp (or we are already root / passwordless).
    //
    // `--protocol tcp` because on python < 3.13 tunneld still defaults to
    // QUIC, which iOS 18.2 removed: every wireless tunnel then fails with
    // QuicProtocolNotSupportedError while USB (always TCP) keeps working.
    // On python >= 3.13 TCP is already the default, so this is a no-op.
    //
    // The interpreter matters as much as the protocol: TCP tunnels need
    // python 3.13's native TLS-PSK. On an older python they fail with
    // `SSL: NO_CIPHERS_AVAILABLE` — logged by tunneld at DEBUG only, so the
    // daemon looks healthy while every wireless tunnel silently dies.
    final tunneld = await pymd.tunneldInvocation();
    if (!tunneld.modernPython) {
      pymd.runner.log.logWarn(
        'no python >= 3.13 with pymobiledevice3 found — wireless (Wi-Fi) '
        'tunnels will likely fail on iOS 18.2+, which only speaks the TCP '
        'tunnel protocol that needs python 3.13. USB devices are '
        'unaffected. Fix: install python3.13+ and '
        '`pip install pymobiledevice3` into it.',
      );
    }
    final argv = await pymd.elevatedArgs([
      'remote',
      'tunneld',
      '--protocol',
      'tcp',
    ], invocation: tunneld.invocation);

    pymd.runner.log.logTrace(
      '[pymobiledevice3] starting RSD tunnel daemon'
      '${sudo != null ? ' (needs root)' : ''}: ${argv.join(' ')}',
    );

    // The sudo prompt above must never be hidden behind the spinner, so the
    // step only covers the spawn + readiness poll.
    await pymd.runner.log.logStep(
      'Starting RSD tunnel daemon',
      () => _startDaemon(argv),
    );
  }

  /// Demand the rights tunneld needs, as a [TunnelPrivilegeError].
  ///
  /// [HostPrivileges] speaks in [CliError], which aborts the whole command.
  /// That is right for `xcross tunnel`, whose only job is the tunnel, and
  /// wrong for a run session: `auto` transport mode has a working userspace
  /// fallback and only reaches it through [TunnelError].
  Future<void> _ensureElevated() async {
    try {
      await pymd.privileges.ensureElevated(
        manualHint:
            'Start tunneld manually:\n'
            '    ${pymd.elevatedCommand('remote tunneld -p tcp')}',
        deniedMessage:
            'xcross needs Administrator rights to create the Windows RSD '
            'tunnel.\n'
            'Open PowerShell with "Run as administrator", then run:\n'
            '    xcross tunnel',
      );
    } on CliError catch (error) {
      throw TunnelPrivilegeError(error.message);
    }
  }

  /// Spawn tunneld with [argv] and poll until its REST API answers.
  Future<void> _startDaemon(List<String> argv) async {
    try {
      await controller.start(
        argv,
        logPath: logPath,
        environment: pymd.usbmuxEnvironment(),
      );
    } on Object catch (error) {
      throw TunnelError('could not start tunneld: $error');
    }

    final up = await ProcessRunner.pollUntil<bool>(
      timeout: const Duration(seconds: 40),
      interval: const Duration(seconds: 1),
      attempt: () async =>
          await isReachable(localHttp: pymd.localHttp) ? true : null,
    );
    if (up ?? false) return;
    await controller.stop();
    throw TunnelError(
      'tunneld did not come up. Try starting it manually in another terminal:\n'
      '    ${pymd.elevatedCommand('remote tunneld -p tcp')}\n'
      'See $logPath for daemon output.',
    );
  }

  Future<bool> restartStale() async {
    if (!controller.ownsProcess) return false;
    await controller.stop();
    await ensureRunning();
    return true;
  }

  void stop() {
    unawaited(
      controller.stop().catchError((Object error) {
        pymd.runner.log.logTrace('could not stop owned tunnel process: $error');
      }),
    );
  }

  /// Whether the tunneld REST API answers. Pure HTTP — never prompts for sudo,
  /// so it is safe as a pre-flight check from stdio-sensitive callers (the DAP).
  static Future<bool> isReachable({
    required LocalHttp<PlatformHostInterface> localHttp,
  }) async {
    try {
      final client = localHttp.client(
        connectionTimeout: const Duration(seconds: 3),
      );
      try {
        final req = await client.getUrl(Uri.parse(TunnelConstants.tunneldUrl));
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

/// Incremental reader of the xcross-started tunneld's log file.
///
/// tunneld runs detached with its output in [TunnelDaemon.logPath], so a
/// failing tunnel (bad pairing record, QUIC-on-modern-iOS, throttling) is
/// invisible in the terminal by default. Tailing the file into the running
/// step is what turns "stuck on Searching for wireless devices" into a
/// visible reason.
final class TunneldLogTail {
  TunneldLogTail._(this._file, this._offset);

  /// Start tailing at the file's current end, so only output produced from
  /// now on is reported (the log persists across runs).
  factory TunneldLogTail.start({
    required String path,
    required HostFileSystemInterface fileSystem,
  }) {
    final file = fileSystem.file(path);
    var offset = 0;
    try {
      if (file.existsSync()) offset = file.lengthSync();
    } on Object {
      // Unreadable log: behave as an always-empty tail.
    }
    return TunneldLogTail._(file, offset);
  }

  final File _file;
  int _offset;
  final StringBuffer _seen = StringBuffer();

  /// Everything read so far.
  String get seen => _seen.toString();

  /// Whether tunneld reported the QUIC protocol failing against a modern
  /// iOS (18.2+ removed QUIC): the signature of a tunneld running with the
  /// wrong `--protocol` on python < 3.13.
  bool get sawQuicUnsupported => seen.contains('QuicProtocolNotSupportedError');

  /// Content appended since the last call (empty when nothing new, the file
  /// is missing, or reading fails).
  String readNew() {
    try {
      if (!_file.existsSync()) return '';
      final length = _file.lengthSync();
      if (length < _offset) _offset = 0; // Truncated/rotated: start over.
      if (length == _offset) return '';
      final raf = _file.openSync();
      try {
        raf.setPositionSync(_offset);
        final bytes = raf.readSync(length - _offset);
        _offset = length;
        final chunk = utf8.decode(bytes, allowMalformed: true);
        _seen.write(chunk);
        return chunk;
      } finally {
        raf.closeSync();
      }
    } on Object {
      return '';
    }
  }
}
