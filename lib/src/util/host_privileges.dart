import 'dart:io';

import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/process.dart';
import 'package:xcross/src/util/sudo.dart';

abstract final class HostPrivileges {
  static bool? _windowsAdministrator;

  static Future<void> ensureDeviceToolAccess({
    bool? windows,
    Future<CapturedProcess> Function()? windowsProbe,
    String? posixManualHint,
  }) async {
    if (!(windows ?? Platform.isWindows)) {
      await Sudo.cacheCredentials(manualHint: posixManualHint);
      return;
    }

    final administrator = windowsProbe != null
        ? await _probeWindowsAdministrator(windowsProbe)
        : _windowsAdministrator ??= await _probeWindowsAdministrator();
    if (administrator) return;
    throw XcrossError(
      'xcross needs Administrator rights to create the Windows RSD tunnel.\n'
      'Open PowerShell with "Run as administrator", then run:\n'
      '    xcross prepare',
    );
  }

  static Future<bool> _probeWindowsAdministrator([
    Future<CapturedProcess> Function()? probe,
  ]) async {
    try {
      final result = probe != null
          ? await probe()
          : await ProcessRunner.run(
              await ProcessRunner.locateTool('powershell'),
              const [
                '-NoProfile',
                '-NonInteractive',
                '-Command',
                '[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)',
              ],
            );
      return result.exitCode == 0 &&
          result.stdout.trim().toLowerCase() == 'true';
    } on Object {
      return false;
    }
  }
}
