import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mobile_device/shared/errors/errors.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:meta/meta.dart';

@internal
final class LockdownTunnelController {
  const LockdownTunnelController(this.pymd, {required this.describeFailure});
  final Pymd pymd;
  final String Function(List<String>) describeFailure;
  static final _tunnelReadyPattern = RegExp(
    'tunnel created|RSD Address|RSD Port',
    caseSensitive: false,
  );
  Future<void> start() async {
    final argv = await pymd.elevatedArgs(['lockdown', 'start-tunnel']);
    final (logPath, logFile) = _openLogFile();

    pymd.runner.log.logTrace(
      '[pymobiledevice3] starting lockdown RSD tunnel'
      ' (background; log: $logPath): ${argv.join(' ')}',
    );

    final proc = await _launch(argv);

    try {
      await proc.stdin.close();
    } on Object catch (_) {}

    final logSink = logFile.openWrite(mode: FileMode.append);
    final ready = _watchReadiness(proc, logSink, logPath);
    await _awaitReady(ready, proc, logPath);

    pymd.runner.log.logTrace(
      '[pymobiledevice3] lockdown RSD tunnel is up '
      '(pid ${proc.pid}; leave it running)',
    );
  }

  (String, File) _openLogFile() {
    final logPath = pymd.runner.host.paths.context.join(
      pymd.runner.host.paths.temporaryRoot,
      'xcross-start-tunnel.log',
    );
    final logFile = pymd.runner.host.fileSystem.file(logPath);
    if (!logFile.existsSync()) logFile.createSync(recursive: true);
    return (logPath, logFile);
  }

  Future<Process> _launch(List<String> argv) async {
    try {
      final proc = await pymd.runner.start(
        argv.first,
        argv.sublist(1),
        environment: pymd.usbmuxEnvironment(),
      );
      return proc;
    } catch (e) {
      throw TunnelError('could not start lockdown start-tunnel: $e');
    }
  }

  Future<void> _watchReadiness(Process proc, IOSink logSink, String logPath) {
    final ready = Completer<void>();

    final recent = <String>[];
    void onLine(String line) {
      final trimmed = line.trimRight();
      if (trimmed.isEmpty) return;
      pymd.runner.log.logTrace(trimmed);
      recent.add(trimmed);
      if (recent.length > 5) recent.removeAt(0);
      if (!ready.isCompleted && _tunnelReadyPattern.hasMatch(trimmed)) {
        ready.complete();
      }
    }

    _teeOutput(proc, logSink, onLine);
    unawaited(
      proc.exitCode.then((code) async {
        try {
          await logSink.flush();
          await logSink.close();
        } on Object catch (_) {}
        if (!ready.isCompleted) {
          ready.completeError(
            TunnelError(
              'lockdown start-tunnel exited early (code $code).\n'
              '${describeFailure(recent)}'
              'See $logPath',
            ),
          );
        }
      }),
    );
    return ready.future;
  }

  Future<void> _awaitReady(
    Future<void> ready,
    Process proc,
    String logPath,
  ) async {
    try {
      await ready.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      await pymd.runner.killTree(proc);
      throw TunnelError(
        'lockdown start-tunnel did not report a tunnel within 60s.\n'
        'Keep the phone unlocked and trusted, then retry:\n'
        '    ${pymd.elevatedCommand('lockdown start-tunnel')}\n'
        'See $logPath for output.',
      );
    } on TunnelError {
      rethrow;
    }
  }

  static void _teeOutput(
    Process proc,
    IOSink logSink,
    void Function(String line) onLine,
  ) {
    for (final raw in [proc.stdout, proc.stderr]) {
      final stream = raw.asBroadcastStream();
      stream.listen(logSink.add, onError: (_) {});
      stream
          // Lossy on purpose: pymobiledevice3 can emit non-UTF-8 bytes, and a
          // strict decoder would drop the whole chunk — losing the ASCII
          // readiness line with it and stalling until the readiness timeout.
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(onLine, onError: (_) {});
    }
  }

  /// Best-effort: a live `start-tunnel` child usually holds a tun interface
  /// and shows up in the process list.
}
