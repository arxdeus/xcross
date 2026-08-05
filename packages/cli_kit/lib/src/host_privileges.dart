import 'dart:io';

import 'package:cli_kit/src/errors.dart';
import 'package:cli_kit/src/process.dart';
import 'package:cli_kit/src/sudo.dart';

/// Ensures the host grants the rights that USB/device tooling needs: a cached
/// sudo ticket on POSIX, an elevated shell on Windows.
abstract final class HostPrivileges {
  /// Prints `True` when the current process runs elevated. Windows has no
  /// `geteuid`; membership of the built-in Administrators role is the check
  /// `net session`-style probes really perform.
  static const _isAdministratorScript =
      '[Security.Principal.WindowsPrincipal]::new('
      '[Security.Principal.WindowsIdentity]::GetCurrent()'
      ').IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)';

  /// Cached across calls: elevation cannot change within one process run.
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
    // An injected probe bypasses the cache so tests stay independent.
    final elevated = windowsProbe != null
        ? await _isWindowsAdministrator(windowsProbe)
        : _windowsAdministrator ??= await _isWindowsAdministrator();
    if (elevated) return;

    throw CliError(
      windowsDeniedMessage ??
          'Administrator rights are required for this operation.\n'
              'Open PowerShell with "Run as administrator" and retry.',
    );
  }

  static Future<bool> _isWindowsAdministrator([
    Future<CapturedProcess> Function()? probe,
  ]) async {
    try {
      final result = await (probe ?? _runAdministratorScript)();
      return result.exitCode == 0 &&
          result.stdout.trim().toLowerCase() == 'true';
    } on Object {
      return false;
    }
  }

  static Future<CapturedProcess> _runAdministratorScript() async =>
      ProcessRunner.run(await ProcessRunner.locateTool('powershell'), const [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        _isAdministratorScript,
      ]);
}
