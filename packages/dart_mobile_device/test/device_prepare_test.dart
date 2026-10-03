import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:dart_mobile_device/src/shared/preparation/tunnel_failure_guidance.dart';
import 'package:test/test.dart';

import 'test_log_output.dart';

void main() {
  test('selected host policies own preparation and service guidance', () {
    final runner = ProcessRunner(
      MacOSHost(),
      log: testLog(),
      stdinStream: const Stream.empty(),
      stdoutSink: testSink(),
      stderrSink: testSink(),
    );
    final linux = LinuxDeviceHost(runner);
    final macos = MacOSDeviceHost(runner);
    final windows = WindowsDeviceHost(runner);
    const failure = ['Failed to connect to usbmuxd socket.'];
    expect(
      linux.describeTunnelFailure(failure),
      contains('sudo systemctl start usbmuxd'),
    );
    expect(macos.describeTunnelFailure(failure), isNot(contains('systemctl')));
    expect(
      windows.describeTunnelFailure(failure),
      isNot(contains('systemctl')),
    );
    expect(windows.preparationDeniedMessage, contains('PowerShell'));
    expect(linux.preparationDeniedMessage, isNot(contains('Windows')));
    expect(macos.preparationDeniedMessage, isNot(contains('Windows')));
    for (final policy in [linux, macos, windows]) {
      final disconnected = policy.describeTunnelFailure([
        'Device is not connected',
      ]);
      expect(disconnected, contains('replug'));
      expect(disconnected, isNot(contains('systemctl')));
    }
  });

  group('DevicePrepare wireless bootstrap', () {
    test('USB lockdown wins even when saved pairings exist', () {
      expect(
        WirelessDevicePreparation.wirelessBootstrapSequence(
          hasUsbDevice: true,
          hasSavedPairings: true,
        ),
        [WirelessBootstrapPath.usbLockdown],
      );
    });

    test('tries saved pairing then falls back to pair-host without USB', () {
      expect(
        WirelessDevicePreparation.wirelessBootstrapSequence(
          hasUsbDevice: false,
          hasSavedPairings: true,
        ),
        [WirelessBootstrapPath.savedPairing, WirelessBootstrapPath.pairHost],
      );
    });

    test('pair-host is only used without USB or saved pairings', () {
      expect(
        WirelessDevicePreparation.wirelessBootstrapSequence(
          hasUsbDevice: false,
          hasSavedPairings: false,
        ),
        [WirelessBootstrapPath.pairHost],
      );
    });

    test('USB bootstrap uses remote pairing over existing lockdown trust', () {
      const udid = '00008030-TEST';
      expect(WirelessDevicePreparation.lockdownRemotePairArgs(udid), [
        'lockdown',
        'remotepairing',
        '--pair',
        '--udid',
        udid,
      ]);
      expect(WirelessDevicePreparation.lockdownWifiArgs(udid), [
        'lockdown',
        'wifi-connections',
        '--state',
        'on',
        '--udid',
        udid,
      ]);
    });
  });

  group('describeDeviceTunnelFailure', () {
    // `lockdown start-tunnel` exits 0 on these failures, so the captured
    // stderr is the only signal about what actually went wrong.
    test('explains a disconnected device', () {
      final message = describeDeviceTunnelFailure([
        'ERROR Device is not connected',
      ]);
      expect(message, contains('Device is not connected'));
      expect(message, contains('replug'));
    });

    test('explains an unreachable usbmuxd', () {
      final message = describeDeviceTunnelFailure([
        'ERROR Failed to connect to usbmuxd socket.',
      ]);
      expect(message, contains('Restore the host device connection service'));
      expect(message, isNot(contains('systemctl')));
    });

    test('passes through unknown output without a hint', () {
      final message = describeDeviceTunnelFailure(['something odd']);
      expect(message.trim(), 'something odd');
    });

    test('is empty when the process said nothing', () {
      expect(describeDeviceTunnelFailure([]), isEmpty);
    });
  });
}
