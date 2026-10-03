import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/setup/setup_script_policy.dart';

final class WindowsSetupScript implements SetupScriptPolicy {
  WindowsSetupScript(this.host, this.runner);

  final PlatformHostInterface host;
  final ProcessRunner runner;

  String get _directory =>
      host.paths.context.join(host.paths.cacheRoot, 'setup-scripts');

  @override
  File cachedFile(String digest) =>
      host.fileSystem.file(host.paths.context.join(_directory, '$digest.ps1'));

  @override
  File cachePointer(String digest) => host.fileSystem.file(
    host.paths.context.join(_directory, '$digest.current'),
  );

  @override
  Future<({String executable, List<String> arguments})> invocation(
    String path,
  ) async => (
    executable: await runner.locateTool('powershell'),
    arguments: ['-NoProfile', '-File', path],
  );

  @override
  void replace(File temporary, File destination) {
    try {
      temporary.renameSync(destination.path);
      return;
    } on FileSystemException {
      if (!destination.existsSync()) rethrow;
    }
    final backup = File(
      '${destination.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.bak',
    );
    destination.renameSync(backup.path);
    try {
      temporary.renameSync(destination.path);
    } on FileSystemException {
      if (!destination.existsSync() && backup.existsSync()) {
        backup.renameSync(destination.path);
      }
      rethrow;
    }
    try {
      backup.deleteSync();
    } on FileSystemException {
      return;
    }
  }
}
