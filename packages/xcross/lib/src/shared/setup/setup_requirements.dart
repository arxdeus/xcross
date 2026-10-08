import 'dart:io';

import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/errors/errors.dart';

@internal
abstract interface class SetupRequirements {
  Future<void> run();
}

@internal
final class SetupRequirementServices {
  SetupRequirementServices({
    required this.host,
    required this.runner,
    required this.privileges,
    required this.console,
    required this.toolchain,
    required this.resolvePipx,
    required this.ensurePymdInstalled,
  });
  final PlatformHostInterface host;
  final ProcessRunner runner;
  final HostPrivilegesInterface privileges;
  final SetupConsole console;
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

@internal
final class SetupConsole {
  const SetupConsole({
    required this.hasTerminal,
    required this.readLine,
    required this.output,
  });
  final bool hasTerminal;
  final String? Function() readLine;
  final IOSink output;
}
