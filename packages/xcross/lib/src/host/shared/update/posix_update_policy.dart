import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/shared/update/update_host_policy.dart';
import 'package:xcross/src/update/install_layout.dart';

Future<FileSwapOperations> preparePosixUpdate(
  PlatformHostInterface host,
  ProcessRunner runner,
  HostPrivilegesInterface privileges,
  InstallLayout layout,
) async {
  if (layout.isWritable) return PosixFileSwapOperations(host);
  runner.log.logInfo('${layout.binDir} is not writable; elevating');
  await privileges.cacheCredentials(
    manualHint: 'Retry with: sudo xcross update',
  );
  final sudo = await privileges.resolve();
  if (sudo == null) {
    throw XcrossError(
      'sudo is required to write the install directory but was not found',
    );
  }
  return ElevatedFileSwapOperations(runner, sudo);
}

final class PosixFileSwapOperations implements FileSwapOperations {
  const PosixFileSwapOperations(this.host);
  final PlatformHostInterface host;
  @override
  Future<void> copy(String source, String target) async {
    await host.fileSystem.file(source).copy(target);
    host.fileSystem.makeExecutable(target);
  }

  @override
  Future<void> move(String source, String target) async {
    await host.fileSystem.file(source).rename(target);
  }

  @override
  Future<void> delete(String path) async {
    await host.fileSystem.file(path).delete();
  }
}

final class ElevatedFileSwapOperations implements FileSwapOperations {
  const ElevatedFileSwapOperations(this.runner, this.sudo);
  final ProcessRunner runner;
  final String sudo;
  Future<void> _run(List<String> arguments) =>
      runner.runChecked(sudo, ['-n', ...arguments], label: 'update');
  @override
  Future<void> copy(String source, String target) =>
      _run(['install', '-m', '0755', source, target]);
  @override
  Future<void> move(String source, String target) =>
      _run(['mv', '-f', source, target]);
  @override
  Future<void> delete(String path) => _run(['rm', '-f', path]);
}
