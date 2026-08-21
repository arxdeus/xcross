import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:xcross/src/device/core_device_launch_profile.dart';
import 'package:xcross/src/device/core_device_launcher.dart';
import 'package:xcross/src/device/device_backend.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/models/pack_result.dart';

typedef OsMajorVersion = Future<int?> Function(Device device);
typedef TerminateInstalledApp =
    Future<void> Function({required String udid, required String bundleId});
typedef LaunchInstalledApp =
    Future<void> Function({
      required String udid,
      required String bundleId,
      required CoreDeviceLaunchProfile profile,
      Future<bool> Function()? onRestartRequested,
    });

final class DeviceRunOperation {
  DeviceRunOperation({
    required this.backend,
    OsMajorVersion? osMajorVersion,
    TerminateInstalledApp? terminate,
    LaunchInstalledApp? launch,
  }) : _osMajorVersion = osMajorVersion ?? _defaultOsMajorVersion,
       _terminate = terminate ?? CoreDeviceLauncher.terminateIfRunning,
       _launch = launch ?? CoreDeviceLauncher.launch;

  static Future<DeviceRunOperation> resolve() async =>
      DeviceRunOperation(backend: await DeviceBackend.resolve());

  static Future<int?> _defaultOsMajorVersion(Device device) =>
      OsVersion.deviceOSMajorVersion(
        device.udid,
        overTunnel: device.source == DeviceSource.tunneld,
      );

  final DeviceBackend backend;
  final OsMajorVersion _osMajorVersion;
  final TerminateInstalledApp _terminate;
  final LaunchInstalledApp _launch;

  Future<Device> run({
    required PackResult pack,
    required String? selector,
    required DeviceSearchMode mode,
    required CoreDeviceLaunchProfile launchProfile,
    Future<bool> Function()? onRestartRequested,
  }) async {
    if (pack.kind != PackOutputKind.app) {
      throw XcrossError(
        'A framework-only KMP build cannot be run on a device.',
      );
    }
    final device = await backend.resolveDevice(selector: selector, mode: mode);
    Log.logInfo('Device', '${device.name} ${Log.ansi.subtle(device.udid)}');
    final major = await _osMajorVersion(device);
    if (major == null) {
      Log.logWarn(
        'Could not read the device OS version; attempting the native '
        'CoreDevice path.',
      );
    }
    if (major != null && major < 17) {
      throw XcrossError('Native device launching requires iOS 17 or later.');
    }
    await _terminate(udid: device.udid, bundleId: pack.bundleId);
    // Launch the exact id install() produced: the device may carry stale
    // team-qualified builds of this app under other identities, and the
    // suffix-matching fallback inside the launcher can land on one of those.
    final installedBundleId = await backend.install(
      pack.appPath,
      device: device,
      bundleId: pack.bundleId,
    );
    await _launch(
      udid: device.udid,
      bundleId: installedBundleId,
      profile: launchProfile,
      onRestartRequested: onRestartRequested,
    );
    return device;
  }
}
