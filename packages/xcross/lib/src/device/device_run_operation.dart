import 'package:apple_developer_kit/apple_developer_kit_shared.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart'
    show Device, DeviceSearchMode, DeviceSource, OsVersion, Pymd;
import 'package:xcross/src/device/core_device_launch_profile.dart';
import 'package:xcross/src/device/core_device_launcher.dart';
import 'package:xcross/src/device/device_backend.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/flutter/hot_reload/vm_service_output.dart';
import 'package:xcross/src/models/pack_result.dart';
import 'package:xcross/src/shared/flutter/vm_service_connector.dart';
import 'package:xcross/src/target/iphone/device/signing_http_client_factory.dart';

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
    required this.log,
    required this.backend,
    required OsMajorVersion osMajorVersion,
    required TerminateInstalledApp terminate,
    required LaunchInstalledApp launch,
  }) : _osMajorVersion = osMajorVersion,
       _terminate = terminate,
       _launch = launch;

  static Future<DeviceRunOperation> resolve(
    Pymd pymd, {
    required AppleHostServices hostServices,
    required NativeLibraryLoader Function() createNativeLibraryLoader,
    required SigningHttpClientFactory httpClients,
    required VmServiceConnector connector,
    required VmServiceOutput vmOutput,
  }) async {
    final launcher = CoreDeviceLauncher(
      pymd,
      connector: connector,
      vmOutput: vmOutput,
    );
    return DeviceRunOperation(
      log: pymd.runner.log,
      backend: await DeviceBackend.resolve(
        pymd,
        hostServices: hostServices,
        createNativeLibraryLoader: createNativeLibraryLoader,
        httpClients: httpClients,
      ),
      osMajorVersion: (device) => OsVersion(pymd).deviceOSMajorVersion(
        device.udid,
        overTunnel: device.source == DeviceSource.tunneld,
      ),
      terminate: launcher.terminateIfRunning,
      launch: launcher.launch,
    );
  }

  final Log log;
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
    log.logInfo('Device', '${device.name} ${log.dim(device.udid)}');
    final major = await _osMajorVersion(device);
    if (major == null) {
      log.logWarn(
        'Could not read the device OS version; attempting the native '
        'CoreDevice path.',
      );
    }
    if (major != null && major < 17) {
      throw XcrossError('Native device launching requires iOS 17 or later.');
    }
    // Launch the exact id install() produced: the device may carry stale
    // team-qualified builds of this app under other identities, and the
    // suffix-matching fallback inside the launcher can land on one of those.
    final installedBundleId = await backend.install(
      pack.appPath,
      device: device,
      bundleId: pack.bundleId,
    );
    await _terminate(udid: device.udid, bundleId: installedBundleId);
    await _launch(
      udid: device.udid,
      bundleId: installedBundleId,
      profile: launchProfile,
      onRestartRequested: onRestartRequested,
    );
    return device;
  }
}
