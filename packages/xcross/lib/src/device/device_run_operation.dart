import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:xcross/src/device/core_device_launch_profile.dart';
import 'package:xcross/src/device/core_device_launcher.dart';
import 'package:xcross/src/device/device_backend.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/models/pack_result.dart';

typedef OsMajorVersion = Future<int?> Function(String udid);
typedef TerminateInstalledApp =
    Future<void> Function({required String udid, required String bundleId});
typedef LaunchInstalledApp =
    Future<void> Function({
      required String udid,
      required String bundleId,
      required CoreDeviceLaunchProfile profile,
    });

final class DeviceRunOperation {
  DeviceRunOperation({
    required this.backend,
    OsMajorVersion? osMajorVersion,
    TerminateInstalledApp? terminate,
    LaunchInstalledApp? launch,
  }) : _osMajorVersion = osMajorVersion ?? OsVersion.deviceOSMajorVersion,
       _terminate = terminate ?? CoreDeviceLauncher.terminateIfRunning,
       _launch = launch ?? CoreDeviceLauncher.launch;

  static Future<DeviceRunOperation> resolve() async =>
      DeviceRunOperation(backend: await DeviceBackend.resolve());

  final DeviceBackend backend;
  final OsMajorVersion _osMajorVersion;
  final TerminateInstalledApp _terminate;
  final LaunchInstalledApp _launch;

  Future<Device> run({
    required PackResult pack,
    required String? selector,
    required DeviceSearchMode mode,
    required CoreDeviceLaunchProfile launchProfile,
  }) async {
    if (pack.kind != PackOutputKind.app) {
      throw XcrossError(
        'A framework-only KMP build cannot be run on a device.',
      );
    }
    final device = await backend.resolveDevice(selector: selector, mode: mode);
    Log.logInfo('Device', '${device.name} ${Log.ansi.subtle(device.udid)}');
    final major = await _osMajorVersion(device.udid);
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
    await backend.install(
      pack.appPath,
      udid: device.udid,
      mode: mode,
      bundleId: pack.bundleId,
    );
    await _launch(
      udid: device.udid,
      bundleId: pack.bundleId,
      profile: launchProfile,
    );
    return device;
  }
}
