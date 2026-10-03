import 'dart:io';

import 'package:cli_kit/src/errors.dart';
import 'package:cli_kit/src/process.dart';
import 'package:cli_kit/src/shared/platform/platform_host.dart';

final class PosixPrivileges<T extends PlatformHostInterface>
    implements HostPrivilegesInterface {
  PosixPrivileges(this.runner);
  final ProcessRunner<T> runner;
  @override
  Future<String?> resolve() => runner.which('sudo');
  @override
  Future<void> ensureElevated({
    String? manualHint,
    String? deniedMessage,
  }) async {
    try {
      await cacheCredentials(manualHint: manualHint);
    } on CliError catch (error) {
      throw CliError(deniedMessage ?? error.message);
    }
  }

  @override
  Future<void> cacheCredentials({String? manualHint}) async {
    final sudo = await resolve();
    if (sudo == null) return;
    runner.log.logInfo(
      'Confirming sudo access ${runner.log.dim('- you may be asked for your password once')}',
    );
    final process = await runner.start(sudo, const [
      '-v',
    ], mode: ProcessStartMode.inheritStdio);
    final code = await process.exitCode;
    if (code != 0) {
      throw CliError(
        'sudo authentication failed (exit $code).\n${manualHint ?? 'Retry with an interactive sudo session.'}',
      );
    }
  }
}
