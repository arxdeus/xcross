import 'package:dart_mobile_device/src/errors.dart';
import 'package:dart_mobile_device/src/host/shared/tunnel/lockdown_tunnel_controller.dart';
import 'package:dart_mobile_device/src/pymd/pymd.dart';
import 'package:dart_mobile_device/src/shared/preparation/device_preparation.dart';
import 'package:dart_mobile_device/src/target/iphone/preparation/developer_disk_image.dart';
import 'package:dart_mobile_device/src/target/iphone/preparation/wireless_device_preparation.dart';
import 'package:dart_mobile_device/src/tunnel/tunnel_daemon.dart';
import 'package:dart_mobile_device/src/tunnel/tunnel_discovery.dart';

/// One-shot iOS 17+ host prep: mount the Developer Disk Image and start the
/// RSD tunnel(s) that [CoreDeviceLauncher] needs.
///
/// Equivalent to the manual:
/// ```sh
/// sudo pymobiledevice3 mounter auto-mount
/// sudo pymobiledevice3 lockdown start-tunnel
/// ```
/// plus ensuring `remote tunneld` is up (the REST discovery path used by
/// `xcross flutter run`).
final class DevicePrepare implements DevicePreparation {
  DevicePrepare(this.pymd);
  final Pymd pymd;
  late final LockdownTunnelController _lockdown = LockdownTunnelController(
    pymd,
    describeFailure: pymd.hostPolicy.describeTunnelFailure,
  );
  late final DeveloperDiskImage _diskImage = DeveloperDiskImage(
    pymd,
    describeFailure: pymd.hostPolicy.describeTunnelFailure,
  );

  /// Mount DDI, ensure tunneld, and start a lockdown RSD tunnel in the
  /// background. Leaves long-lived processes running after return.
  ///
  /// USB only: the wireless bring-up (pairing advertisement, Wi-Fi tunnel,
  /// tunnel-routed DDI mount) lives in [prepareWireless] behind an explicit
  /// `--wifi`, so the cable path stays simple and never blocks waiting for
  /// a phone that is not there.
  @override
  Future<void> prepare() async {
    await _prepareSteps();
    pymd.runner.log.logDone(
      'Device ready '
      '${pymd.runner.log.dim('— DDI mounted, RSD tunnel up')}',
    );
    pymd.runner.log.logInfo(
      'Next',
      pymd.runner.log.dim('xcross flutter run -u <UDID>'),
    );
  }

  @override
  Future<void> prepareWireless() =>
      WirelessDevicePreparation(pymd, diskImage: _diskImage).prepare();

  /// The same steps as [prepare], without the closing banner.
  ///
  /// Called mid-session when tunneld itself refused to create a tunnel: every
  /// step is idempotent, so a session that only lacks the Developer Disk Image
  /// or a lockdown tunnel repairs itself instead of silently degrading.
  Future<void> repairRsdTunnel() => _prepareSteps();

  Future<void> _prepareSteps() async {
    if (!await pymd.ensureInstalled()) {
      throw TunnelError(
        'pymobiledevice3 is required but could not be installed automatically.',
      );
    }

    await pymd.privileges.ensureElevated(
      manualHint:
          'Start prepare steps manually:\n'
          '    ${pymd.elevatedCommand('mounter auto-mount')}\n'
          '    ${pymd.elevatedCommand('lockdown start-tunnel')}',
      deniedMessage: pymd.hostPolicy.preparationDeniedMessage,
    );

    // tunneld first: it needs no device and `_ensureLockdownTunnel` skips
    // itself when tunneld already carries a tunnel.
    await TunnelDaemon(pymd).ensureRunning();
    await _diskImage.mountUsb();
    await _ensureLockdownTunnel();
  }

  /// `pymobiledevice3 mounter auto-mount --rsd <host> <port>` — mounts the
  /// DDI through the RSD tunnel itself, the only route that reaches a
  /// wireless-only device. Needs no root.
  /// Start `lockdown start-tunnel` in the background if one is not already
  /// producing an RSD tunnel. Leaves the process running after prepare exits.
  ///
  /// Skips when tunneld already exposes a tunnel: on Windows a second
  /// `lockdown start-tunnel` creates another WinTun adapter for the same
  /// device and breaks IPv6 RSD connectivity (connect → WinError 10013).
  Future<void> _ensureLockdownTunnel() async {
    if (await _tunneldHasTunnel()) {
      pymd.runner.log.logTrace(
        'tunneld already has an RSD tunnel; skipping lockdown start-tunnel',
      );
      return;
    }
    if (await _lockdownTunnelLooksAlive()) {
      pymd.runner.log.logTrace('lockdown start-tunnel already running');
      return;
    }
    await pymd.runner.log.logStep(
      'Starting lockdown RSD tunnel',
      _lockdown.start,
    );
  }

  /// True when the local tunneld REST API already lists at least one tunnel.
  Future<bool> _tunneldHasTunnel() async =>
      await TunnelDiscovery(
        pymd.runner.log,
        localHttp: pymd.localHttp,
      ).findExistingTunnel() !=
      null;

  Future<bool> _lockdownTunnelLooksAlive() =>
      pymd.hostPolicy.lockdownTunnelLooksAlive();
}
