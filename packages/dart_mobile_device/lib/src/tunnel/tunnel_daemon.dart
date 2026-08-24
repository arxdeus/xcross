import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/src/constants.dart';
import 'package:dart_mobile_device/src/errors.dart';
import 'package:dart_mobile_device/src/pymd/pymd.dart';
import 'package:path/path.dart' as p;

/// Manages the `pymobiledevice3 remote tunneld` daemon lifecycle.
///
/// * If tunneld REST API is already reachable → reuse it (no ownership taken).
/// * Otherwise → start `[sudo] pymobiledevice3 remote tunneld` as background
///   child, wait up to 40 s for it to come up.
/// * [stop] tears down only a daemon we started ourselves.
class TunnelDaemon {
  Process? _process;

  /// Where an xcross-started tunneld's output goes. One fixed path (not a
  /// fresh temp file per run) so a stale daemon from a previous run is
  /// diagnosable from the current one.
  static String get logPath =>
      p.join(Directory.systemTemp.path, 'xcross-tunneld.log');

  /// Where an xcross-started tunneld's pid is recorded, so a *later* xcross
  /// process can replace a stale daemon it did not start itself (e.g. one
  /// still speaking QUIC to an iOS that removed it).
  static String get pidFilePath =>
      p.join(Directory.systemTemp.path, 'xcross-tunneld.pid');

  /// Whether we started the daemon. When false, [stop] leaves the user's own
  /// long-running tunneld alone instead of SIGTERMing it on exit.
  bool _ownsDaemon = false;

  /// Ensure a tunneld REST API is reachable; start one if needed.
  Future<void> ensureRunning() async {
    if (await isReachable()) {
      // A reachable daemon can still be useless: an xcross-started tunneld
      // from an earlier run may speak QUIC (removed in iOS 18.2) or run on a
      // python < 3.13 whose TCP tunnels fail with SSL: NO_CIPHERS_AVAILABLE
      // — a failure tunneld logs at DEBUG only, so it *looks* healthy while
      // every wireless tunnel dies. When today's launch decision differs
      // from what that daemon runs, replace it (never a user-started one).
      if (!_ownsDaemon && await _staleDaemonIncompatible()) {
        Log.logWarn(
          'an xcross-started tunneld from a previous run is incompatible '
          'with wireless tunnels on modern iOS — replacing it',
        );
        if (await restartStale()) return;
        Log.logTrace('stale tunneld replacement failed; reusing it as-is');
      }
      Log.logTrace('RSD tunnel daemon already running (reusing it)');
      return;
    }

    await _ensureElevated();
    final sudo = await Sudo.resolve();

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
    final tunneld = await Pymd.tunneldInvocation();
    if (!tunneld.modernPython) {
      Log.logWarn(
        'no python >= 3.13 with pymobiledevice3 found — wireless (Wi-Fi) '
        'tunnels will likely fail on iOS 18.2+, which only speaks the TCP '
        'tunnel protocol that needs python 3.13. USB devices are '
        'unaffected. Fix: install python3.13+ and '
        '`pip install pymobiledevice3` into it.',
      );
    }
    final argv = await Pymd.elevatedArgs([
      'remote',
      'tunneld',
      '--protocol',
      'tcp',
    ], invocation: tunneld.invocation);

    Log.logTrace(
      '[pymobiledevice3] starting RSD tunnel daemon'
      '${sudo != null ? ' (needs root)' : ''}: ${argv.join(' ')}',
    );

    // The sudo prompt above must never be hidden behind the spinner, so the
    // step only covers the spawn + readiness poll.
    await Log.logStep('Starting RSD tunnel daemon', () => _startDaemon(argv));
  }

  /// Demand the rights tunneld needs, as a [TunnelPrivilegeError].
  ///
  /// [HostPrivileges] speaks in [CliError], which aborts the whole command.
  /// That is right for `xcross tunnel`, whose only job is the tunnel, and
  /// wrong for a run session: `auto` transport mode has a working userspace
  /// fallback and only reaches it through [TunnelError].
  static Future<void> _ensureElevated() async {
    try {
      await HostPrivileges.ensureDeviceToolAccess(
        posixManualHint:
            'Start tunneld manually:\n'
            '    ${Pymd.elevatedCommand('remote tunneld -p tcp')}',
        windowsDeniedMessage:
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
      throw TunnelError('could not start tunneld: $e');
    }

    // Detach from our TTY completely — daemon must not consume keypresses.
    try {
      await proc.stdin.close();
    } catch (_) {}
    final logSink = logFile.openWrite(mode: FileMode.append);
    proc.stdout.listen(logSink.add, onError: (_) {});
    proc.stderr.listen(logSink.add, onError: (_) {});
    unawaited(
      proc.exitCode.then((_) async {
        try {
          await logSink.flush();
          await logSink.close();
        } catch (_) {}
      }),
    );

    _process = proc;
    _ownsDaemon = true;
    _writePidFile(proc.pid);

    final up = await ProcessRunner.pollUntil<bool>(
      timeout: const Duration(seconds: 40),
      interval: const Duration(seconds: 1),
      attempt: () async => await isReachable() ? true : null,
    );
    if (up ?? false) return;
    throw TunnelError(
      'tunneld did not come up. Try starting it manually in another terminal:\n'
      '    ${Pymd.elevatedCommand('remote tunneld -p tcp')}\n'
      'See $logPath for daemon output.',
    );
  }

  static void _writePidFile(int pid) {
    try {
      File(pidFilePath).writeAsStringSync('$pid');
    } on Object catch (e) {
      Log.logTrace('could not write tunneld pid file: $e');
    }
  }

  /// Whether the pid-file daemon was launched differently from how tunneld
  /// would be launched right now — older xcross versions used the default
  /// QUIC protocol, and pre-modern-python ones an interpreter whose TCP
  /// tunnels cannot work. False when there is no (live) pid-file daemon.
  static Future<bool> _staleDaemonIncompatible() async {
    if (Platform.isWindows) return false;
    final String cmdline;
    try {
      final pid = int.parse(File(pidFilePath).readAsStringSync().trim());
      cmdline = File('/proc/$pid/cmdline').readAsStringSync();
    } on Object {
      return false;
    }
    if (!cmdline.contains('tunneld')) return false;
    // /proc cmdline is NUL-separated; compare per-argument.
    final args = cmdline.split('\x00');
    if (!args.contains('tcp')) return true;
    final tunneld = await Pymd.tunneldInvocation();
    return tunneld.modernPython &&
        !args.contains(tunneld.invocation.executable);
  }

  /// Replace an xcross-started tunneld from a *previous* run with a fresh
  /// one, and take ownership of the replacement. Returns false when there is
  /// no such daemon to replace (no pid file, pid not a tunneld, or Windows,
  /// where a stale elevated daemon cannot be signalled from here).
  ///
  /// Only the pid-file daemon is ever killed — a tunneld the user started
  /// in their own terminal is never touched.
  Future<bool> restartStale() async {
    if (_ownsDaemon || Platform.isWindows) return false;
    final int pid;
    try {
      pid = int.parse(File(pidFilePath).readAsStringSync().trim());
    } on Object {
      return false;
    }
    // The pid file may outlive the process and the pid may since have been
    // recycled: only ever signal something that is still tunneld. The
    // recorded pid is sudo's, whose cmdline carries the full command it ran.
    final String cmdline;
    try {
      cmdline = File('/proc/$pid/cmdline').readAsStringSync();
    } on Object {
      return false;
    }
    if (!cmdline.contains('tunneld')) return false;

    Log.logTrace('replacing stale tunneld (pid $pid)');
    // Prompt for sudo *before* `sudo -n kill`: the credential cache from the
    // run that started this daemon has usually expired by now.
    await _ensureElevated();
    final sudo = await Sudo.resolve();
    try {
      if (sudo != null) {
        // sudo relays SIGTERM to the elevated tunneld it is running.
        await ProcessRunner.run(sudo, ['-n', 'kill', '-TERM', '$pid']);
      } else {
        Process.killPid(pid);
      }
    } on Object catch (e) {
      Log.logTrace('could not signal stale tunneld: $e');
      return false;
    }
    final down = await ProcessRunner.pollUntil<bool>(
      timeout: const Duration(seconds: 10),
      interval: const Duration(milliseconds: 500),
      attempt: () async => await isReachable() ? null : true,
    );
    if (!(down ?? false)) return false;
    await ensureRunning();
    return true;
  }

  /// Tear down only the daemon WE started. Safe to call multiple times.
  void stop() {
    if (!_ownsDaemon) return;
    final proc = _process;
    _process = null;
    _ownsDaemon = false;
    if (proc == null) return;

    Log.logTrace('stopping RSD tunnel daemon…');

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

  /// Whether the tunneld REST API answers. Pure HTTP — never prompts for sudo,
  /// so it is safe as a pre-flight check from stdio-sensitive callers (the DAP).
  static Future<bool> isReachable() async {
    try {
      final client = LocalHttp.client(
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
  factory TunneldLogTail.start({String? path}) {
    final file = File(path ?? TunnelDaemon.logPath);
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
