import 'dart:async';
import 'dart:convert';

import 'package:cli_kit/shared/process/process_models.dart';
import 'package:meta/meta.dart';
import 'package:pure/pure.dart';

@internal
abstract final class ProcessHelpers {
  static String failureMessage(
    String executable,
    List<String> arguments,
    int exitCode, {
    required ProcessExitDiagnostic diagnostic,
    String output = '',
    bool captured = true,
  }) {
    final detail = diagnostic.description;
    final message = StringBuffer('command failed ($exitCode')
      ..write(detail == null ? '' : ': $detail')
      ..write('): ${commandLine(executable, arguments)}');
    if (output.trim().isNotEmpty) {
      message.write('\n$output');
    } else if (captured && diagnostic.crashed) {
      message.write(
        '\nIt wrote nothing before dying. Re-run with --verbose: that hands '
        'the tool this terminal instead of a pipe, which is the only way its '
        'crash message survives.',
      );
    }
    return message.toString();
  }

  static final _plainArgument = RegExp(r'^[a-zA-Z0-9_./:=+,-]+$');

  static String commandLine(String executable, List<String> arguments) =>
      [executable, ...arguments]
          .map(
            (value) =>
                _plainArgument.hasMatch(value) ? value : jsonEncode(value),
          )
          .join(' ');

  static Stream<T> pausingBroadcast<T>(Stream<T> source) =>
      source.asBroadcastStream(
        onListen: (sub) => callIf(sub.isPaused, sub.resume),
        onCancel: (sub) => sub.pause(),
      );

  static String bracketHost(String addr) =>
      addr.contains(':') ? '[$addr]' : addr;

  static String unbracketHost(String host) =>
      host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;

  static Future<T?> pollUntil<T>({
    required Future<T?> Function() attempt,
    required Duration timeout,
    required Duration interval,
    bool Function()? cancelled,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (cancelled?.call() ?? false) return null;
      try {
        final result = await attempt();
        if (result != null) return result;
      } catch (_) {}
      await Future<void>.delayed(interval);
    }
    return null;
  }
}
