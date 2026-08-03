import 'dart:io';

import 'package:cli_kit/src/errors.dart';
import 'package:cli_kit/src/process.dart';
import 'package:cli_kit/src/sudo.dart';

abstract final class HostPrivileges {
  static bool? _windowsAdministrator;

  static Future<void> ensureDeviceToolAccess({
    bool? windows,
    Future<CapturedProcess> Function()? windowsProbe,
    String? posixManualHint,
    String? windowsDeniedMessage,
  }) async {
    if (!(windows ?? Platform.isWindows)) {
      await Sudo.cacheCredentials(manualHint: posixManualHint);
      return;
    }

    final administrator = windowsProbe != null
        ? await _probeWindowsAdministrator(windowsProbe)
        : _windowsAdministrator ??= await _probeWindowsAdministrator();
    if (administrator) return;
    throw CliError(
      windowsDeniedMessage ??
          'Administrator rights are required for this operation.\n'
              'Open PowerShell with "Run as administrator" and retry.',
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
