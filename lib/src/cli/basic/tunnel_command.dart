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
class TunnelCommand extends Command<void> {
  @override
  String get name => 'tunnel';

  @override
  String get description =>
      'Mount the Developer Disk Image and start the iOS 17+ RSD tunnel '
      '(mounter auto-mount + lockdown start-tunnel + tunneld). '
      'Requires sudo on POSIX or an Administrator terminal on Windows.';

  @override
  Future<void> run() => DevicePrepare.prepare();
}
