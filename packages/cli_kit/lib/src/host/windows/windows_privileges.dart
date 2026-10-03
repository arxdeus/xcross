import 'package:cli_kit/src/errors.dart';
import 'package:cli_kit/src/process.dart';
import 'package:cli_kit/src/shared/platform/platform_host.dart';

final class WindowsPrivileges<T extends PlatformHostInterface>
    implements HostPrivilegesInterface {
  WindowsPrivileges(
    this.runner, {
    Future<CapturedProcess> Function()? administratorProbe,
  }) : _administratorProbe = administratorProbe;
  final ProcessRunner<T> runner;
  final Future<CapturedProcess> Function()? _administratorProbe;
  bool? _administrator;
  static const _script =
      '[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)';
  @override
  Future<String?> resolve() async => null;
  @override
  Future<void> cacheCredentials({String? manualHint}) async {}
  @override
  Future<void> ensureElevated({
    String? manualHint,
    String? deniedMessage,
  }) async {
    final elevated = _administrator ??= await _probe();
    if (elevated) return;
    throw CliError(
      deniedMessage ??
          'Administrator rights are required for this operation.\nOpen PowerShell with "Run as administrator" and retry.',
    );
  }

  Future<bool> _probe() async {
    try {
      final result = _administratorProbe != null
          ? await _administratorProbe()
          : await runner.run(await runner.locateTool('powershell'), const [
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              _script,
            ]);
      return result.exitCode == 0 &&
          result.stdout.trim().toLowerCase() == 'true';
    } on Object {
      return false;
    }
  }
}
