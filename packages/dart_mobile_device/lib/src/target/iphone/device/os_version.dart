import 'dart:convert';

import 'package:dart_mobile_device/src/target/iphone/device/pymd/pymd.dart';

/// Groups device OS version detection.
final class OsVersion {
  OsVersion(this.pymd);
  final Pymd pymd;

  /// Major OS version for [udid], via `lockdown info` then `ideviceinfo`.
  /// Returns null if neither tool can provide [ProductVersion].
  ///
  /// [overTunnel] reads through tunneld's RSD tunnel (`--tunnel`) instead of
  /// usbmuxd (`--udid`) — required for wireless devices on Linux/Windows,
  /// where usbmuxd cannot reach them at all.
  Future<int?> deviceOSMajorVersion(
    String udid, {
    bool overTunnel = false,
  }) async =>
      await _majorFromPymdLockdown(udid, overTunnel: overTunnel) ??
      (overTunnel ? null : await _majorFromIdeviceinfo(udid));

  Future<int?> _majorFromPymdLockdown(
    String udid, {
    required bool overTunnel,
  }) async {
    try {
      // Bounded: over a wireless tunnel a napping phone can stretch this
      // read arbitrarily, and the version gate must not hang the run — a
      // null answer already degrades gracefully at the caller.
      final result = await pymd.run([
        'lockdown',
        'info',
        if (overTunnel) ...['--tunnel', udid] else ...['--udid', udid],
      ], timeout: const Duration(seconds: 30));
      final stdout = result.stdout.trim();
      if (stdout.isEmpty) {
        pymd.runner.log.logWarn(
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
      pymd.runner.log.logWarn(
        'Could not determine device OS version via pymobiledevice3: $e',
      );
      return null;
    }
  }

  Future<int?> _majorFromIdeviceinfo(String udid) async {
    try {
      final result = await pymd.runner.run(
        await pymd.runner.locateTool('ideviceinfo'),
        ['-u', udid, '-k', 'ProductVersion'],
      );
      if (result.exitCode != 0) {
        final msg = result.stderr.trim().isNotEmpty
            ? result.stderr.trim()
            : result.stdout;
        pymd.runner.log.logWarn('ideviceinfo ProductVersion failed: $msg');
        return null;
      }
      return _majorFromVersionString(result.stdout.trim());
    } catch (e) {
      pymd.runner.log.logWarn(
        'Could not determine device OS version via ideviceinfo: $e',
      );
      return null;
    }
  }

  static int? _majorFromVersionString(String version) {
    if (version.isEmpty) return null;
    return int.tryParse(version.split('.').first);
  }
}
