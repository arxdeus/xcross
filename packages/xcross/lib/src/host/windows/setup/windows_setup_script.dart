import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/runtime/version.dart';
import 'package:xcross/src/shared/setup/setup_script_policy.dart';

@internal
final class WindowsSetupScript implements SetupScriptPolicy {
  WindowsSetupScript(this.host, this.runner);

  final PlatformHostInterface host;
  final ProcessRunner runner;

  /// Windows has no package manager xcross drives in-process, so setup runs
  /// the repository's script for whichever of winget, Scoop or Chocolatey is
  /// installed, pinned to the release this binary was built from
  /// (development builds follow `main`).
  @override
  Future<List<DefaultSetupScript>> defaultSources() async {
    final installed = [
      for (final manager in managers)
        if (await runner.which(manager) != null)
          (manager: manager, source: scriptUrl(_ref, manager)),
    ];
    // Without any package manager, download the vendor installers directly.
    return installed.isEmpty
        ? [(manager: direct, source: scriptUrl(_ref, direct))]
        : installed;
  }

  @override
  Future<DefaultSetupScript?> sourceFor(String manager) async {
    if (manager != direct && await runner.which(manager) == null) return null;
    return (manager: manager, source: scriptUrl(_ref, manager));
  }

  @override
  List<String> get supportedManagers => [...managers, direct];

  /// Package managers with a script named after their executable, in
  /// preference order.
  static const managers = {'winget', 'scoop', 'choco'};

  /// Script that installs everything from vendor downloads.
  static const direct = 'direct';

  /// Release tag this binary was built from; development builds follow main.
  static const _ref = XcrossVersion.isReleased
      ? 'v${XcrossVersion.current}'
      : 'main';

  static String scriptUrl(String ref, String manager) =>
      'https://raw.githubusercontent.com/arxdeus/xcross/$ref/setup/$manager.ps1';

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
    // Client Windows defaults to the Restricted execution policy, which
    // refuses every -File script; the user has already approved this one.
    arguments: ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path],
  );

  @override
  void replace(File temporary, File destination) {
    try {
      temporary.renameSync(destination.path);
      return;
    } on FileSystemException {
      if (!destination.existsSync()) rethrow;
    }
    final backup = host.fileSystem.file(
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
