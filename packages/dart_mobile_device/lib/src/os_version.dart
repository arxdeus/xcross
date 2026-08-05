import 'dart:convert';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/src/pymd.dart';

/// Groups device OS version detection.
abstract final class OsVersion {
  /// Return the major OS version for [udid] by querying the device.
  ///
  /// Prefers `pymobiledevice3 lockdown info`, then falls back to
  /// `ideviceinfo` (libimobiledevice) when pymobiledevice3 returns
  /// empty/unparseable output — common on WSL/usbipd where lockdown JSON is
  /// empty but the UDID still lists.
  ///
  /// Returns null if neither tool can provide [ProductVersion]. Callers reject
  /// confirmed pre-iOS-17 devices and attempt CoreDevice when it is unknown.
  static Future<int?> deviceOSMajorVersion(String udid) async =>
      await _majorFromPymdLockdown(udid) ?? await _majorFromIdeviceinfo(udid);

  static Future<int?> _majorFromPymdLockdown(String udid) async {
    try {
      final result = await Pymd.run(['lockdown', 'info', '--udid', udid]);
      final stdout = result.stdout.trim();
      if (stdout.isEmpty) {
        Log.logWarn(
          'pymobiledevice3 lockdown info returned empty stdout '
          '(exit ${result.exitCode}); trying ideviceinfo…',
        );
        return null;
      }
      if (jsonDecode(stdout) case {'ProductVersion': final String version}) {
        return _majorFromVersionString(version);
      }
      return null;
    } catch (e) {
      Log.logWarn(
        'Could not determine device OS version via pymobiledevice3: $e',
      );
      return null;
    }
  }

  static Future<int?> _majorFromIdeviceinfo(String udid) async {
    try {
      final result = await ProcessRunner.run('ideviceinfo', [
        '-u',
        udid,
        '-k',
        'ProductVersion',
      ]);
      if (result.exitCode != 0) {
        final msg = result.stderr.trim().isNotEmpty
            ? result.stderr.trim()
            : result.stdout;
        Log.logWarn('ideviceinfo ProductVersion failed: $msg');
        return null;
      }
      return _majorFromVersionString(result.stdout.trim());
    } catch (e) {
      Log.logWarn('Could not determine device OS version via ideviceinfo: $e');
      return null;
    }
  }

  static int? _majorFromVersionString(String version) {
    if (version.isEmpty) return null;
    return int.tryParse(version.split('.').first);
  }
}
