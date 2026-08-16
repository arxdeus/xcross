import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:test/test.dart';

void main() {
  group('TunnelPrivilegeError', () {
    // `DeviceTransportResolver` in `auto` mode only degrades to the userspace
    // tunnel from a `TunnelError`. When an unprivileged shell reported a bare
    // `CliError` instead, a fully built and signed app died at the last step
    // on Windows rather than running over usbmux.
    test('is a TunnelError so auto mode can fall back to userspace', () {
      expect(TunnelPrivilegeError('denied'), isA<TunnelError>());
    });

    test('is distinguishable from a plain TunnelError', () {
      expect(TunnelError('boom'), isNot(isA<TunnelPrivilegeError>()));
    });

    test('keeps the actionable message verbatim', () {
      const message =
          'xcross needs Administrator rights to create the Windows RSD '
          'tunnel.';
      expect(TunnelPrivilegeError(message).toString(), message);
    });
  });
}
