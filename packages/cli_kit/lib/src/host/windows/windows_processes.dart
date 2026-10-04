import 'dart:async';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:cli_kit/src/host/shared/native_tool_lookup.dart';
import 'package:cli_kit/src/host/shared/owned_processes.dart';
import 'package:cli_kit/src/host/windows/windows_batch.dart';
import 'package:meta/meta.dart';

@internal
final class WindowsProcesses implements HostProcessInterface {
  WindowsProcesses({
    required HostPathsInterface paths,
    required HostEnvironmentInterface environment,
    required HostFileSystemInterface fileSystem,
    Future<ProcessResult> Function(
      String,
      List<String>, {
      Map<String, String>? environment,
      bool includeParentEnvironment,
    })?
    runProcess,
  }) : _paths = paths,
       _environment = environment,
       _fileSystem = fileSystem,
       _runProcess = runProcess ?? Process.run;
  final OwnedProcesses _owned = OwnedProcesses();
  final HostPathsInterface _paths;
  final HostEnvironmentInterface _environment;
  final HostFileSystemInterface _fileSystem;
  final Future<ProcessResult> Function(
    String,
    List<String>, {
    Map<String, String>? environment,
    bool includeParentEnvironment,
  })
  _runProcess;

  static const _statuses = <int, String>{
    0xC0000005: 'STATUS_ACCESS_VIOLATION, a bad pointer dereference',
    0xC000001D: 'STATUS_ILLEGAL_INSTRUCTION',
    0xC000007B: 'STATUS_INVALID_IMAGE_FORMAT, a wrong-architecture binary',
    0xC00000FD: 'STATUS_STACK_OVERFLOW',
    0xC0000135: 'STATUS_DLL_NOT_FOUND, a DLL it needs is not on PATH',
    0xC0000139: 'STATUS_ENTRYPOINT_NOT_FOUND, a DLL on PATH is the wrong build',
    0xC0000142: 'STATUS_DLL_INIT_FAILED',
    0xC0000374: 'STATUS_HEAP_CORRUPTION',
    0xC0000409:
        'STATUS_STACK_BUFFER_OVERRUN, which is how Windows reports abort(), '
        'normally a failed assertion or a fatal error inside the tool',
  };

  @override
  ProcessExitDiagnostic describeExit(int exitCode) {
    final isStatus = exitCode >= 0
        ? exitCode >= 0xC0000000 && exitCode <= 0xFFFFFFFF
        : exitCode >= -0x40000000 && exitCode <= -256;
    if (!isStatus) {
      return const ProcessExitDiagnostic(crashed: false, description: null);
    }
    final status = exitCode < 0 ? exitCode + 0x100000000 : exitCode;
    final hex = '0x${status.toRadixString(16).toUpperCase()}';
    final known = _statuses[status];
    return ProcessExitDiagnostic(
      crashed: true,
      description: known == null
          ? '$hex, an NTSTATUS crash code: the tool died instead of exiting'
          : '$hex $known',
    );
  }

  @override
  Future<String?> findOnShellPath(
    String name, {
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async => null;
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
    Future.sync(() {
      final batch = WindowsBatchPolicy.isBatchScript(executable);
      return Process.start(
        executable,
        batch
            ? WindowsBatchPolicy.arguments(arguments, executable: executable)
            : arguments,
        workingDirectory: _paths.ioPath(
          workingDirectory ?? _paths.context.current,
        ),
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: runInShell || batch,
        mode: mode,
      );
    }),
    mode,
  );
  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) async {
    if (!_owned.contains(process)) return;
    try {
      final taskkill = locateNativeCleanupTool(
        'taskkill',
        paths: _paths,
        environment: _environment,
        fileSystem: _fileSystem,
        childEnvironment: environment,
        executableOverrides: executableOverrides,
      );
      if (taskkill == null) {
        process.kill();
        return;
      }
      await _runProcess(
        _paths.ioPath(taskkill),
        ['/PID', '${process.pid}', '/T', '/F'],
        environment: environment ?? _environment.values,
        includeParentEnvironment: false,
      );
    } on Object {
      process.kill();
      return;
    }
    process.kill();
  }
}
