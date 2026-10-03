import 'dart:async';

import 'package:pure/pure.dart';

abstract final class ProcessHelpers {
  static const _windowsStatuses = <int, String>{
    0xC0000005: 'STATUS_ACCESS_VIOLATION, a bad pointer dereference',
    0xC000001D: 'STATUS_ILLEGAL_INSTRUCTION',
    0xC000007B: 'STATUS_INVALID_IMAGE_FORMAT, a wrong-architecture binary',
    0xC00000FD: 'STATUS_STACK_OVERFLOW',
    0xC0000135: 'STATUS_DLL_NOT_FOUND, a DLL it needs is not on PATH',
    0xC0000139: 'STATUS_ENTRYPOINT_NOT_FOUND, a DLL on PATH is the wrong build',
    0xC0000142: 'STATUS_DLL_INIT_FAILED',
    0xC0000374: 'STATUS_HEAP_CORRUPTION',
    0xC0000409:
        'STATUS_STACK_BUFFER_OVERRUN, which is how Windows reports abort() — '
        'normally a failed assertion or a fatal error inside the tool',
  };

  static const _ntStatusError = 0xC0000000;

  static int _asNtStatus(int exitCode) =>
      exitCode < 0 ? exitCode + 0x1_0000_0000 : exitCode;

  static bool _isNtStatus(int exitCode) => exitCode >= 0
      ? exitCode >= _ntStatusError
      : exitCode >= _ntStatusError - 0x1_0000_0000 && exitCode <= -256;

  static bool crashed(int exitCode) =>
      _isNtStatus(exitCode) || (exitCode < 0 && exitCode > -256);

  static String? describeExitCode(int exitCode) {
    if (!_isNtStatus(exitCode)) {
      return exitCode < 0 ? 'killed by signal ${-exitCode}' : null;
    }
    final status = _asNtStatus(exitCode);
    final hex = '0x${status.toRadixString(16).toUpperCase()}';
    final known = _windowsStatuses[status];
    if (known != null) return '$hex $known';
    return '$hex, an NTSTATUS crash code: the tool died instead of exiting';
  }

  static String failureMessage(
    String executable,
    List<String> arguments,
    int exitCode, {
    String output = '',
    bool captured = true,
  }) {
    final detail = describeExitCode(exitCode);
    final message = StringBuffer('command failed ($exitCode')
      ..write(detail == null ? '' : ': $detail')
      ..write('): ${commandLine(executable, arguments)}');
    if (output.trim().isNotEmpty) {
      message.write('\n$output');
    } else if (captured && crashed(exitCode)) {
      message.write(
        '\nIt wrote nothing before dying. Re-run with --verbose: that hands '
        'the tool this terminal instead of a pipe, which is the only way its '
        'crash message survives.',
      );
    }
    return message.toString();
  }

  static final _shellSpecialCharsPattern = RegExp(r'''[\s'"\\$`]''');

  static String commandLine(String executable, List<String> arguments) =>
      [executable, ...arguments].map(_shellQuote).join(' ');

  static String _shellQuote(String s) {
    if (s.isEmpty) return "''";
    if (!_shellSpecialCharsPattern.hasMatch(s)) return s;
    return "'${s.replaceAll("'", r"'\''")}'";
  }

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
