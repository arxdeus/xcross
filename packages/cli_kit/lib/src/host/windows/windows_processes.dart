import 'dart:async';
import 'dart:io';

import 'package:cli_kit/src/host/shared/native_tool_lookup.dart';
import 'package:cli_kit/src/host/shared/owned_processes.dart';
import 'package:cli_kit/src/host/windows/windows_batch.dart';
import 'package:cli_kit/src/host/windows/windows_environment.dart';
import 'package:cli_kit/src/host/windows/windows_file_system.dart';
import 'package:cli_kit/src/host/windows/windows_paths.dart';
import 'package:cli_kit/src/shared/platform/platform_host.dart';

final class WindowsProcesses implements HostProcessInterface {
  WindowsProcesses({
    HostPathsInterface? paths,
    HostEnvironmentInterface? environment,
    HostFileSystemInterface? fileSystem,
    Future<ProcessResult> Function(
      String,
      List<String>, {
      Map<String, String>? environment,
      bool includeParentEnvironment,
    })?
    runProcess,
  }) : _paths = paths ?? WindowsPaths(),
       _environment = environment ?? WindowsEnvironment(const {}),
       _fileSystem = fileSystem ?? WindowsFileSystem(paths ?? WindowsPaths()),
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
        taskkill,
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
