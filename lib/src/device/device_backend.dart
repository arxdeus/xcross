import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/appstoreconnect/appstoreconnect.dart';
import 'package:xcross/src/device/pymd_device_resolver.dart';
import 'package:xcross/src/device/pymd_devices.dart';
import 'package:xcross/src/models/device/device.dart';
import 'package:xcross/src/signing/zsign_cli.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/process.dart';
import 'package:xcross/src/xtool/xtool_cli.dart';

/// Resolves and installs to a device, backed by either the upstream `xtool`
/// binary (Linux/macOS, unchanged behavior) or the native (no-Swift)
/// App Store Connect + zsign + pymobiledevice3 pipeline (Windows and anywhere
/// else `xtool` isn't installed).
abstract class DeviceBackend {
  Future<Device> resolveDevice({
    required DeviceSearchMode mode,
    String? selector,
  });

  Future<void> install(
    String appOrIpaPath, {
    required String udid,
    required DeviceSearchMode mode,
    required String bundleId,
  });

  /// [XtoolBackend] if the `xtool` binary is found on PATH (existing,
  /// unchanged Linux/macOS behavior), else [NativeBackend].
  static Future<DeviceBackend> resolve() async {
    final xtoolPath = await ProcessRunner.which('xtool');
    return xtoolPath != null ? XtoolBackend() : NativeBackend();
  }
}

/// Delegates straight to [XtoolCli] — zero behavior change from the
/// pre-existing `xtool`-only code path.
class XtoolBackend implements DeviceBackend {
  XtoolBackend([XtoolCli? xtool]) : xtool = xtool ?? XtoolCli();

  final XtoolCli xtool;

  @override
  Future<Device> resolveDevice({
    required DeviceSearchMode mode,
    String? selector,
  }) => xtool.resolveDevice(selector: selector, mode: mode);

  @override
  Future<void> install(
    String appOrIpaPath, {
    required String udid,
    required DeviceSearchMode mode,
    required String bundleId,
  }) => xtool.install(appOrIpaPath, udid: udid, mode: mode);
}

/// Swift/xtool-free pipeline: pymobiledevice3 for device discovery/install,
/// App Store Connect API + zsign for provisioning and signing.
class NativeBackend implements DeviceBackend {
  NativeBackend([PymdDeviceResolver? resolver])
    : _resolver = resolver ?? PymdDeviceResolver();

  final PymdDeviceResolver _resolver;

  @override
  Future<Device> resolveDevice({
    required DeviceSearchMode mode,
    String? selector,
  }) => _resolver.resolveDevice(selector: selector, mode: mode);

  @override
  Future<void> install(
    String appOrIpaPath, {
    required String udid,
    required DeviceSearchMode mode,
    required String bundleId,
  }) async {
    final configPath = AscCredentials.defaultConfigPath();
    if (!File(configPath).existsSync()) {
      throw XcrossError(
        'No App Store Connect credentials configured (needed to provision a '
        'Development certificate/profile without xtool). Run:\n'
        '    xcross auth --issuer-id <id> --key-id <id> '
        '--private-key <path-to-AuthKey_XXXX.p8>',
      );
    }
    final credentials = await AscCredentials.fromFile(configPath);
    final client = AscClient(credentials);
    try {
      final outputDir = p.join(p.dirname(configPath), 'signing', bundleId);
      final identity = await provisionDevelopmentIdentity(
        client: client,
        bundleId: bundleId,
        deviceUdids: [udid],
        outputDir: outputDir,
      );
      await ZsignCli().sign(
        appOrIpaPath: appOrIpaPath,
        privateKeyPemPath: identity.privateKeyPemPath,
        certificatePemPath: identity.certificatePemPath,
        provisioningProfilePath: identity.profilePath,
        outputPath: appOrIpaPath,
      );
      await PymdDevices.install(appOrIpaPath, udid: udid);
    } finally {
      client.close();
    }
  }
}
