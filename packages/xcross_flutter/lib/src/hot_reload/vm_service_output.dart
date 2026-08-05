import 'dart:convert';
import 'dart:io';

import 'package:xcross_flutter/src/hot_reload/dart_vm_service_client.dart';

/// Forwards the app's `print` / `stderr` / `dart:developer log()` output from
/// the Dart VM Service to this process's stdout and stderr.
abstract final class VmServiceOutput {
  /// The app is launched by pymobiledevice3 and the debugger only *attaches*
  /// afterwards, so debugserver never owns the inferior's stdio and emits no
  /// `O` packets for it — GDB output forwarding alone shows nothing. The VM
  /// Service `Stdout`/`Stderr`/`Logging` streams are the only channel that
  /// carries it. The reference Flutter debug adapter does the same on attach
  /// (see `_subscribeToOutputStreams` in the DAP's `attachRequest`).
  static Future<void> forwardVmServiceOutput(DartVmServiceClient vm) async {
    // Under `xcross dap` the debug adapter subscribes to Logging itself
    // (unconditionally, unlike Stdout/Stderr) and renders records with full
    // untruncated strings — forwarding here too would print every line twice.
    final ownsLogging = Platform.environment['XCROSS_DAP'] != '1';

    // Subscribe before listening: the VM only publishes a stream that has a
    // subscriber, so anything printed before this point is genuinely lost.
    await vm.streamListen('Stdout');
    await vm.streamListen('Stderr');
    if (ownsLogging) await vm.streamListen('Logging');

    vm.events.listen((event) {
      switch (event['streamId']) {
        case 'Stdout':
          if (decodeStreamWrite(event) case final text?) stdout.write(text);
        case 'Stderr':
          if (decodeStreamWrite(event) case final text?) stderr.write(text);
        case 'Logging' when ownsLogging:
          if (formatLogRecord(event) case final text?) stdout.write(text);
      }
    });
  }

  /// Decode a `Stdout`/`Stderr` `WriteEvent` payload, which carries base64
  /// bytes.
  ///
  /// Returns null when there is nothing to print. Malformed UTF-8 is passed
  /// through with replacement chars rather than dropping the line: partial
  /// sequences are normal because the VM chunks writes at arbitrary offsets.
  static String? decodeStreamWrite(Map<String, dynamic> event) {
    if (event['bytes'] case final String bytes when bytes.isNotEmpty) {
      try {
        return utf8.decode(base64Decode(bytes), allowMalformed: true);
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  /// Render a `Logging` `LogRecord` the way the reference adapter does:
  /// `[loggerName] message`.
  ///
  /// Only `valueAsString` is read. A message long enough to be truncated by
  /// the VM would need a follow-up `getObject` round trip, which is not worth
  /// a round trip per log line.
  static String? formatLogRecord(Map<String, dynamic> event) {
    if (event['logRecord'] case final Map<String, dynamic> record) {
      final name = _valueAsString(record['loggerName']);
      final prefix = '[${name == null || name.isEmpty ? 'log' : name}] ';
      final lines = [
        for (final key in const ['message', 'error', 'stackTrace'])
          if (_valueAsString(record[key]) case final value?
              when value.isNotEmpty)
            '$prefix$value',
      ];
      if (lines.isNotEmpty) return '${lines.join('\n')}\n';
    }
    return null;
  }

  /// A `LogRecord`'s unset `error`/`stackTrace` arrive as a Null *instance*
  /// (`{kind: Null, valueAsString: 'null'}`), not as an absent field — so the
  /// kind must be checked, or every `log('x')` prints a spurious
  /// `[log] null` line for each of them.
  static String? _valueAsString(Object? instanceRef) => switch (instanceRef) {
    {'kind': 'Null'} => null,
    {'valueAsString': final String value} => value,
    _ => null,
  };
}
