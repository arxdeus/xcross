import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:test/test.dart';

void main() {
  final runner = ProcessRunner(MacOSHost(environment: Platform.environment));
  final pymd = Pymd(runner, hostPolicy: MacOSDeviceHost(runner));
  group('Pymd.asPort', () {
    test('passes through an int unchanged', () {
      expect(Pymd.asPort(12345), 12345);
    });

    test('parses a numeric String', () {
      expect(Pymd.asPort('12345'), 12345);
    });

    test('returns null for a non-numeric String', () {
      expect(Pymd.asPort('not-a-number'), isNull);
    });

    test('returns null for null', () {
      expect(Pymd.asPort(null), isNull);
    });

    test('returns null for a double (neither int nor String)', () {
      expect(Pymd.asPort(3.14), isNull);
    });

    test('returns null for an unrelated type like a List', () {
      expect(Pymd.asPort(<int>[1, 2]), isNull);
    });
  });

  group('Pymd.usbmuxEnvironment', () {
    test('is a superset of Platform.environment', () {
      final env = pymd.usbmuxEnvironment();
      for (final entry in Platform.environment.entries) {
        expect(env[entry.key], entry.value);
      }
    });
  });

  group('Pymd.resolvedUsbmuxAddress', () {
    // The exact value is machine-dependent (usbmuxd socket presence and env
    // vars vary by host), so this pins the documented contract instead of a
    // hardcoded value: when USBMUXD_SOCKET_ADDRESS is set it must be returned
    // verbatim; otherwise it must match the real /var/run/usbmuxd existence
    // check exactly (not just "is null or a String", which a String? return
    // type already guarantees and so can never fail).
    test('honours USBMUXD_SOCKET_ADDRESS when set, else mirrors '
        '/var/run/usbmuxd existence', () {
      final envValue = Platform.environment['USBMUXD_SOCKET_ADDRESS'];
      final result = pymd.resolvedUsbmuxAddress();

      if (envValue != null && envValue.isNotEmpty) {
        expect(result, envValue);
      } else {
        final usbmuxdExists = File('/var/run/usbmuxd').existsSync();
        expect(result, usbmuxdExists ? '/var/run/usbmuxd' : isNull);
      }
    });
  });
}
