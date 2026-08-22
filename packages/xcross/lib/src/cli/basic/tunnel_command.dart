import 'package:args/command_runner.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';

/// `xcross tunnel` — mount the Developer Disk Image and start the iOS 17+
/// RSD tunnel(s) needed by `xcross flutter run`.
///
/// Automates:
/// ```sh
/// sudo pymobiledevice3 mounter auto-mount
/// sudo pymobiledevice3 lockdown start-tunnel
/// ```
/// and also ensures `pymobiledevice3 remote tunneld` is running (REST discovery
/// used by CoreDevice launch). Long-lived tunnel processes are left running
/// after the command exits.
///
/// With `--wifi`, an attached phone is paired for RemotePairing through its
/// USB lockdown connection. Without USB, saved devices are reconnected first;
/// only a host with no saved devices advertises device-initiated pairing
/// (iOS 27+, the 6-digit code prints here).
final class TunnelCommand extends Command<void> {
  TunnelCommand() {
    argParser.addFlag(
      'wifi',
      negatable: false,
      help:
          'Set up a wireless device: bootstrap pairing over USB when attached, '
          'otherwise reconnect a saved device or advertise pairing on iOS 27+.',
    );
  }

  @override
  String get name => 'tunnel';

  @override
  String get description =>
      'Mount the Developer Disk Image and start the iOS 17+ RSD tunnel '
      '(mounter auto-mount + lockdown start-tunnel + tunneld). '
      'With --wifi: pair over USB when available, otherwise reconnect a saved '
      'device or pair on-device, then tunnel over Wi-Fi. '
      'Requires sudo on POSIX or an Administrator terminal on Windows.';

  @override
  Future<void> run() => argResults!.flag('wifi')
      ? DevicePrepare.prepareWireless()
      : DevicePrepare.prepare();
}
