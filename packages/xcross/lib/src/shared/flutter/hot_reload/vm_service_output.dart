import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/hot_reload/dart_vm_service_client.dart';

/// Forwards the app's `print` / `stderr` / `dart:developer log()` output from
/// the Dart VM Service to this process's stdout and stderr.
@internal
final class VmServiceOutput {
  VmServiceOutput({required this.output, required this.errors});
  final StringSink output;
  final StringSink errors;

  /// The debugger only *attaches* after launch, so debugserver never owns
  /// the inferior's stdio; the VM Service `Stdout`/`Stderr`/`Logging`
  /// streams are the only channel that carries app output.
  Future<void> forwardVmServiceOutput(
    DartVmServiceClient vm, {
    required bool ownsLogging,
  }) async {
    // Under `xcross dap` the debug adapter subscribes to Logging itself
    // (unconditionally, unlike Stdout/Stderr) and renders records with full
    // untruncated strings — forwarding here too would print every line twice.

    // Subscribe before listening: the VM only publishes a stream that has a
    // subscriber, so anything printed before this point is genuinely lost.
    await vm.streamListen('Stdout');
    await vm.streamListen('Stderr');
    if (ownsLogging) await vm.streamListen('Logging');

    vm.events.listen((event) {
      switch (event['streamId']) {
        case 'Stdout':
          if (decodeStreamWrite(event) case final text?) output.write(text);
        case 'Stderr':
          if (decodeStreamWrite(event) case final text?) errors.write(text);
        case 'Logging' when ownsLogging:
          if (formatLogRecord(event) case final text?) output.write(text);
      }
    });
  }

  /// Decode a `Stdout`/`Stderr` `WriteEvent`'s base64 payload, or null when
  /// empty. Malformed UTF-8 is passed through with replacement chars since
  /// the VM chunks writes at arbitrary offsets.
  static String? decodeStreamWrite(Map<String, dynamic> event) {
    if (event case {'bytes': final String bytes} when bytes.isNotEmpty) {
      try {
        return utf8.decode(base64Decode(bytes), allowMalformed: true);
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  /// Render a `Logging` `LogRecord` as `[loggerName] message`. Only
  /// `valueAsString` is read; a truncated message is not worth a follow-up
  /// `getObject` round trip.
  static String? formatLogRecord(Map<String, dynamic> event) {
    if (event case {'logRecord': final Map<String, dynamic> record}) {
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

  // Unset error/stackTrace arrive as a Null instance, not an absent field,
  // so `kind` must be checked or every log prints a spurious "null" line.
  static String? _valueAsString(Object? instanceRef) => switch (instanceRef) {
    {'kind': 'Null'} => null,
    {'valueAsString': final String value} => value,
    _ => null,
  };
}
