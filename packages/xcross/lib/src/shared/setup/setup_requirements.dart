import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/errors.dart';

abstract interface class SetupRequirements {
  Future<void> run();
}

final class SetupRequirementServices {
  SetupRequirementServices({
    required this.host,
    required this.runner,
    required this.privileges,
    required this.toolchain,
    required this.resolvePipx,
    required this.ensurePymdInstalled,
  });
  final PlatformHostInterface host;
  final ProcessRunner runner;
  final HostPrivilegesInterface privileges;
  final DarwinToolchainResolver toolchain;
  final Future<String?> Function() resolvePipx;
  final Future<bool> Function() ensurePymdInstalled;
  Future<void> runFirstWorking(
    List<List<String>> attempts, {
    required String label,
    Step? tail,
  }) async {
    for (var i = 0; i < attempts.length; i++) {
      final attempt = attempts[i];
      runner.log.logTrace('[$label] running: ${attempt.join(' ')}');
      try {
        await runner.runChecked(
          attempt.first,
          attempt.sublist(1),
          label: label,
          tail: tail,
        );
        return;
      } on Object {
        if (i == attempts.length - 1) rethrow;
      }
    }
  }

  Future<String> ensurePipx({
    required List<List<String>> attempts,
    required String manualHint,
  }) async {
    final existing = await resolvePipx();
    if (existing != null) return existing;

    final step = runner.log.beginStep('Installing pipx');
    for (final attempt in attempts) {
      runner.log.logTrace('[pipx] running: ${attempt.join(' ')}');
      final result = await runner.run(attempt.first, attempt.sublist(1));
      if (result.exitCode != 0) continue;
      final pipx = await resolvePipx();
      if (pipx != null) {
        step.done();
        return pipx;
      }
    }

    step.fail();
    throw XcrossError('Could not install pipx.\n$manualHint');
  }

  Future<void> pipxEnsurePath(String pipx) async {
    try {
      await runner.runChecked(pipx, ['ensurepath'], label: 'pipx ensurepath');
    } on Object catch (error) {
      runner.log.logWarn(
        'pipx ensurepath failed, add ~/.local/bin to PATH: $error',
      );
    }
  }

  Future<void> ensurePymd() async {
    if (!await ensurePymdInstalled()) {
      throw XcrossError('pymobiledevice3 install failed; see above.');
    }
  }

  Future<List<String>> missingTools(List<String> tools) async {
    final missing = <String>[];
    for (final tool in tools) {
      if (await locate(tool) == null) missing.add(tool);
    }
    return missing;
  }

  Future<String?> locate(String tool) => runner.which(
    tool,
    accept: tool == 'ld64.lld' ? toolchain.usableLd64Lld : null,
    extraDirectories: toolchain.llvmToolDirs(),
  );
}
