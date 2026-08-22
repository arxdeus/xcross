import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:test/test.dart';

void main() {
  group('DevicePrepare wireless bootstrap', () {
    test('USB lockdown wins even when saved pairings exist', () {
      expect(
        DevicePrepare.selectWirelessBootstrapPath(
          hasUsbDevice: true,
          hasSavedPairings: true,
        ),
        WirelessBootstrapPath.usbLockdown,
      );
    });

    test('reuses saved pairing when there is no USB device', () {
      expect(
        DevicePrepare.selectWirelessBootstrapPath(
          hasUsbDevice: false,
          hasSavedPairings: true,
        ),
        WirelessBootstrapPath.savedPairing,
      );
    });

    test('pair-host is only used without USB or saved pairings', () {
      expect(
        DevicePrepare.selectWirelessBootstrapPath(
          hasUsbDevice: false,
          hasSavedPairings: false,
        ),
        WirelessBootstrapPath.pairHost,
      );
    });

    test('USB bootstrap uses classic and remote lockdown pairing', () {
      const udid = '00008030-TEST';
      expect(DevicePrepare.lockdownPairArgs(udid), [
        'lockdown',
        'pair',
        '--udid',
        udid,
      ]);
      expect(DevicePrepare.lockdownRemotePairArgs(udid), [
        'lockdown',
        'remotepairing',
        '--pair',
        '--udid',
        udid,
      ]);
      expect(DevicePrepare.lockdownWifiArgs(udid), [
        'lockdown',
        'wifi-connections',
        '--state',
        'on',
        '--udid',
        udid,
      ]);
    });
  });

  group('DevicePrepare.explainTunnelExit', () {
    // `lockdown start-tunnel` exits 0 on these failures, so the captured
    // stderr is the only signal about what actually went wrong.
    test('explains a disconnected device', () {
      final message = DevicePrepare.explainTunnelExit([
        'ERROR Device is not connected',
      ]);
      expect(message, contains('Device is not connected'));
      expect(message, contains('replug'));
    });

    test('explains an unreachable usbmuxd', () {
      final message = DevicePrepare.explainTunnelExit([
        'ERROR Failed to connect to usbmuxd socket.',
      ]);
      expect(message, contains('systemctl start usbmuxd'));
    });

    test('passes through unknown output without a hint', () {
      final message = DevicePrepare.explainTunnelExit(['something odd']);
      expect(message.trim(), 'something odd');
    });

    test('is empty when the process said nothing', () {
      expect(DevicePrepare.explainTunnelExit([]), isEmpty);
    });
  });
}
