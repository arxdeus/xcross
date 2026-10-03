import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/src/host/shared/owned_processes.dart';
import 'package:cli_kit/src/shared/platform/platform_host.dart';

final class PosixProcesses implements HostProcessInterface {
  PosixProcesses();
  final OwnedProcesses _owned = OwnedProcesses();
  @override
  Future<String?> findOnShellPath(
    String name, {
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async {
    final process = await start(
      '/bin/sh',
      ['-c', r'command -v "$1"', 'sh', name],
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
    );
    final output = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final errors = process.stderr.drain<void>();
    final value = (await output).trim();
    await errors;
    final code = await process.exitCode;
    return code == 0 && value.isNotEmpty ? value : null;
  }

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) => _owned.track(
    Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      mode: mode,
    ),
    mode,
  );
  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) async {
    if (_owned.contains(process)) process.kill();
  }
}
