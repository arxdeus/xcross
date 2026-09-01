import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:meta/meta.dart';

@internal
final class DeviceLog {
  DeviceLog._(this._process, this._pid);

  static const _cleanupTimeout = Duration(seconds: 2);

  final Process _process;
  final int _pid;
  late final StreamSubscription<String> _stdout;
  late final StreamSubscription<String> _stderr;

  @visibleForTesting
  static Map<String, String> processEnvironment(Map<String, String> base) => {
    ...base,
    'PYTHONUNBUFFERED': '1',
    'PYTHONIOENCODING': 'utf-8',
  };

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

  static Future<DeviceLog?> start({
    required List<String> deviceArgs,
    required int pid,
    required bool enabled,
  }) async {
    if (!enabled) return null;
    try {
      final invocation = await Pymd.resolve();
      final process = await ProcessRunner.start(invocation.executable, [
        ...invocation.prefixArgs,
        'developer',
        'dvt',
        'oslog',
        ...deviceArgs,
        '--pid',
        '$pid',
        '--format',
        'json',
      ], environment: processEnvironment(Pymd.usbmuxEnvironment()));
      final log = DeviceLog._(process, pid).._listen();
      unawaited(
        process.exitCode.then((code) {
          if (code != 0) {
            Log.logTrace('device log stream exited with code $code');
          }
        }),
      );
      Log.logInfo('Device logs', 'streaming for pid $pid');
      return log;
    } on Object catch (e) {
      Log.logWarn('could not stream device logs: $e');
      return null;
    }
  }

  void _listen() {
    _stdout = _process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          final message = appLogMessage(line, _pid);
          if (message != null) stdout.writeln('[device] $message');
        });
    _stderr = _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) => Log.logTrace('device log: $line'));
  }

  Future<void> close() async {
    _process.kill();
    await _stdout.cancel();
    await _stderr.cancel();
    try {
      await _process.exitCode.timeout(_cleanupTimeout);
    } on TimeoutException {
      Log.logTrace('cleanup device-log timed out');
    }
  }
}
