import 'dart:convert';

import 'package:test/test.dart';
import 'package:xcross/src/device/vm_service_output.dart';

Map<String, dynamic> _write(String text) =>
    {'streamId': 'Stdout', 'bytes': base64Encode(utf8.encode(text))};

Map<String, dynamic> _log({
  String? logger,
  String? message,
  String? error,
  String? stack,
}) =>
    {
      'streamId': 'Logging',
      'logRecord': {
        if (logger != null) 'loggerName': {'valueAsString': logger},
        if (message != null) 'message': {'valueAsString': message},
        if (error != null) 'error': {'valueAsString': error},
        if (stack != null) 'stackTrace': {'valueAsString': stack},
      },
    };

void main() {
  group('decodeStreamWrite', () {
    test('decodes base64 payloads, including non-ASCII', () {
      expect(decodeStreamWrite(_write('hello\n')), 'hello\n');
      expect(decodeStreamWrite(_write('héllo ✓ 日\n')), 'héllo ✓ 日\n');
    });

    test('survives a multi-byte sequence split by the VM mid-character', () {
      final bytes = utf8.encode('日本');
      final first =
          decodeStreamWrite({'bytes': base64Encode(bytes.sublist(0, 2))});
      // Must not throw or drop the chunk; a replacement char is acceptable.
      expect(first, isNotNull);
    });

    test('returns null when there is nothing to print', () {
      expect(decodeStreamWrite({'bytes': ''}), isNull);
      expect(decodeStreamWrite(const {}), isNull);
      expect(decodeStreamWrite({'bytes': 'not base64!!'}), isNull);
    });
  });

  group('formatLogRecord', () {
    test('prefixes with the logger name', () {
      expect(formatLogRecord(_log(logger: 'auth', message: 'signed in')),
          '[auth] signed in\n');
    });

    test('falls back to [log] when the logger is unnamed', () {
      expect(formatLogRecord(_log(message: 'plain')), '[log] plain\n');
      expect(
          formatLogRecord(_log(logger: '', message: 'plain')), '[log] plain\n');
    });

    test('includes error and stack trace, each prefixed', () {
      expect(
        formatLogRecord(_log(
            logger: 'net', message: 'failed', error: 'boom', stack: 'at x')),
        '[net] failed\n[net] boom\n[net] at x\n',
      );
    });

    test('returns null when the record carries no text', () {
      expect(formatLogRecord(_log(logger: 'empty')), isNull);
      expect(formatLogRecord(const {'streamId': 'Logging'}), isNull);
      // A non-string InstanceRef (an object, not a primitive) has no
      // valueAsString and must be skipped rather than crash the listener.
      expect(
        formatLogRecord({
          'logRecord': {
            'message': {'type': '@Instance', 'classRef': <String, Object?>{}},
          },
        }),
        isNull,
      );
    });
  });
}
