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
/// With `--wifi` the cable is not used at all: tunneld is started, this host
/// is advertised for device-initiated pairing (iOS 27+, the 6-digit code
/// prints here), and the DDI is mounted through the wireless RSD tunnel.
final class TunnelCommand extends Command<void> {
  TunnelCommand() {
    argParser.addFlag(
      'wifi',
      negatable: false,
      help:
          'Set up a wireless device: advertise this host for pairing '
          '(iOS 27+) and build the tunnel over Wi-Fi, no cable involved.',
    );
  }

  @override
  String get name => 'tunnel';

  @override
  String get description =>
      'Mount the Developer Disk Image and start the iOS 17+ RSD tunnel '
      '(mounter auto-mount + lockdown start-tunnel + tunneld). '
      'With --wifi: pair and tunnel over Wi-Fi instead, no cable needed. '
      'Requires sudo on POSIX or an Administrator terminal on Windows.';

  @override
  Future<void> run() => argResults!.flag('wifi')
      ? DevicePrepare.prepareWireless()
      : DevicePrepare.prepare();
}
