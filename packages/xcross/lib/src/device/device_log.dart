import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:meta/meta.dart';

@internal
final class DeviceLog {
  DeviceLog._(this._process, this._pid);

  /// A log with no attached process, for exercising the crash-reason buffer.
  @visibleForTesting
  DeviceLog.forTesting() : _process = null, _pid = 0;

  static const _cleanupTimeout = Duration(seconds: 2);

  /// How many of the app's own log lines to retain for crash diagnosis.
  ///
  /// Generous on purpose: an iOS app emits a torrent of framework chatter
  /// (networking, reachability, agent bookkeeping) between the abort reason
  /// and the fault itself, and a short buffer loses the one line that
  /// matters.
  @visibleForTesting
  static const recentLineLimit = 400;

  /// How many of those lines to actually print when no reason line was found.
  /// Bounded separately so a crash never dumps hundreds of lines.
  @visibleForTesting
  static const printedLineLimit = 20;

  /// The newest [printedLineLimit] lines, oldest first.
  List<String> get tailLines {
    final all = _recent.toList();
    final from = all.length <= printedLineLimit
        ? 0
        : all.length - printedLineLimit;
    return List.unmodifiable(all.sublist(from));
  }

  final Process? _process;
  final int _pid;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;

  /// Ring buffer of the app's most recent log lines, kept even when the
  /// session is not verbose: it is the only place a native crash reason
  /// (`NSException`, `FIRApp` misconfiguration, …) ever shows up.
  final Queue<String> _recent = Queue<String>();

  /// The app's last log lines, oldest first.
  List<String> get recentLines => List.unmodifiable(_recent);

  /// The line that explains a native abort, if the app printed one.
  String? get crashReason {
    for (final line in _recent.toList().reversed) {
      if (_crashReasonPattern.hasMatch(line)) return line.trim();
    }
    return null;
  }

  static final _crashReasonPattern = RegExp(
    'Terminating app due to uncaught exception|'
    'Fatal error|'
    r'\bassertion failed\b|'
    'FATAL EXCEPTION',
    caseSensitive: false,
  );

  @visibleForTesting
  static Map<String, String> processEnvironment(Map<String, String> base) => {
    ...base,
    'PYTHONUNBUFFERED': '1',
    'PYTHONIOENCODING': 'utf-8',
  };

  /// Device-selection arguments for the log stream.
  ///
  /// Deliberately NOT the session transport's args: `--userspace --udid …`
  /// opens a *second* in-process tunnel to a device that already has one,
  /// which stalls for minutes and silently yields no log lines at all — the
  /// app then crashes with no explanation on screen. `syslog` rides plain
  /// usbmux (lockdown), needs neither a tunnel nor a mounted DDI, and streams
  /// immediately.
  @visibleForTesting
  static List<String> deviceSelectionArgs(String? udid) => [
    if (udid != null) ...['--udid', udid],
  ];

  /// Extract the app's own message from one `syslog live --format json`
  /// (or legacy `dvt oslog --format json`) line, dropping other processes.
  @visibleForTesting
  static String? appLogMessage(String line, int pid) {
    try {
      final entry = jsonDecode(line);
      if (entry is! Map<String, dynamic> || entry['pid'] != pid) return null;
      return entry['message'] as String?;
    } on FormatException {
      return null;
    }
  }

  /// Start streaming the launched app's logs.
  ///
  /// [verbose] only decides whether lines are echoed live; the stream itself
  /// always runs so [crashReason] can explain a fatal stop.
  static Future<DeviceLog?> start({
    required int pid,
    String? udid,
    bool verbose = false,
  }) async {
    try {
      final invocation = await Pymd.resolve();
      final process = await ProcessRunner.start(invocation.executable, [
        ...invocation.prefixArgs,
        'syslog',
        'live',
        ...deviceSelectionArgs(udid),
        '--pid',
        '$pid',
        '--format',
        'json',
      ], environment: processEnvironment(Pymd.usbmuxEnvironment()));
      final log = DeviceLog._(process, pid).._listen(echo: verbose);
      unawaited(
        process.exitCode.then((code) {
          if (code != 0) {
            Log.logTrace('device log stream exited with code $code');
          }
        }),
      );
      Log.logTrace('device logs streaming for pid $pid');
      return log;
    } on Object catch (e) {
      Log.logWarn('could not stream device logs: $e');
      return null;
    }
  }

  void _listen({required bool echo}) {
    final process = _process!;
    _stdout = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          final message = appLogMessage(line, _pid);
          if (message == null) return;
          _remember(message);
          if (echo) stdout.writeln('[device] $message');
        });
    _stderr = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) => Log.logTrace('device log: $line'));
  }

  @visibleForTesting
  void rememberForTesting(String message) => _remember(message);

  void _remember(String message) {
    _recent.addLast(message);
    while (_recent.length > recentLineLimit) {
      _recent.removeFirst();
    }
  }

  Future<void> close() async {
    final process = _process;
    if (process == null) return;
    process.kill();
    await _stdout?.cancel();
    await _stderr?.cancel();
    try {
      await process.exitCode.timeout(_cleanupTimeout);
    } on TimeoutException {
      Log.logTrace('cleanup device-log timed out');
    }
  }
}
