import 'dart:convert';

import 'package:xcross/src/device/pymd.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';

/// Return the major OS version for [udid] by querying the device.
///
/// Prefers `pymobiledevice3 lockdown info`, then falls back to `ideviceinfo`
/// (libimobiledevice) when pymobiledevice3 returns empty/unparseable output —
/// common on WSL/usbipd where lockdown JSON is empty but the UDID still lists.
///
/// Returns null if neither tool can provide [ProductVersion]. Callers use this
/// to gate iOS 17+ (CoreDeviceLauncher) vs pre-17 (DebugLauncher).
Future<int?> deviceOSMajorVersion(String udid) async {
  final fromPymd = await _majorFromPymdLockdown(udid);
  if (fromPymd != null) return fromPymd;

  final fromIdevice = await _majorFromIdeviceinfo(udid);
  if (fromIdevice != null) return fromIdevice;

  return null;
}

Future<int?> _majorFromPymdLockdown(String udid) async {
  try {
    final result = await Pymd.run(['lockdown', 'info', '--udid', udid]);
    final stdout = result.stdout.trim();
    if (stdout.isEmpty) {
      logWarn(
        'pymobiledevice3 lockdown info returned empty stdout '
        '(exit ${result.exitCode}); trying ideviceinfo…',
      );
      return null;
    }
    final Object? json = jsonDecode(stdout);
    if (json is! Map) return null;
    final Object? version = json['ProductVersion'];
    if (version is! String) return null;
    return _majorFromVersionString(version);
  } catch (e) {
    logWarn('Could not determine device OS version via pymobiledevice3: $e');
    return null;
  }
}

Future<int?> _majorFromIdeviceinfo(String udid) async {
  try {
    final result = await ProcessRunner.run(
      'ideviceinfo',
      ['-u', udid, '-k', 'ProductVersion'],
    );
    if (result.exitCode != 0) {
      final msg =
          result.stderr.trim().isNotEmpty ? result.stderr.trim() : result.stdout;
      logWarn('ideviceinfo ProductVersion failed: $msg');
      return null;
    }
    return _majorFromVersionString(result.stdout.trim());
  } catch (e) {
    logWarn('Could not determine device OS version via ideviceinfo: $e');
    return null;
  }
}

int? _majorFromVersionString(String version) {
  if (version.isEmpty) return null;
  return int.tryParse(version.split('.').first);
}
