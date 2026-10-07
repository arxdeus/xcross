import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/setup/setup_script_policy.dart';

@internal
final class PosixSetupScript implements SetupScriptPolicy {
  PosixSetupScript(this.host);

  final PlatformHostInterface host;

  @override
  Future<List<DefaultSetupScript>> defaultSources() async => const [];

  @override
  Future<DefaultSetupScript?> sourceFor(String manager) async => null;

  @override
  List<String> get supportedManagers => const [];

  String get _directory =>
      host.paths.context.join(host.paths.cacheRoot, 'setup-scripts');

  @override
  File cachedFile(String digest) =>
      host.fileSystem.file(host.paths.context.join(_directory, '$digest.sh'));

  @override
  File cachePointer(String digest) => host.fileSystem.file(
    host.paths.context.join(_directory, '$digest.current'),
  );

  @override
  Future<({String executable, List<String> arguments})> invocation(
    String path,
  ) async => (executable: '/bin/sh', arguments: [path]);

  @override
  void replace(File temporary, File destination) =>
      temporary.renameSync(destination.path);
}
