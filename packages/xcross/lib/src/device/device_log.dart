import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:meta/meta.dart';

@internal
final class DeviceLog {
  DeviceLog._(this._process);

  static const _cleanupTimeout = Duration(seconds: 2);

  final Process _process;
  late final StreamSubscription<String> _stdout;
  late final StreamSubscription<String> _stderr;

  static Future<DeviceLog?> start({
    required List<String> deviceArgs,
    required int pid,
  }) async {
    try {
      final invocation = await Pymd.resolve();
      final process = await Process.start(invocation.executable, [
        ...invocation.prefixArgs,
        'developer',
        'dvt',
        'oslog',
        ...deviceArgs,
        '--pid',
        '$pid',
      ], environment: Pymd.usbmuxEnvironment());
      final log = DeviceLog._(process).._listen();
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
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => stdout.writeln('[device] $line'));
    _stderr = _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => stderr.writeln('[device] $line'));
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
