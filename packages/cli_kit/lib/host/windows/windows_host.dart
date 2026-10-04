import 'package:cli_kit/host/windows/windows_paths.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/src/host/windows/windows_environment.dart';
import 'package:cli_kit/src/host/windows/windows_file_system.dart';
import 'package:cli_kit/src/host/windows/windows_processes.dart';

final class WindowsHost implements WindowsHostInterface {
  WindowsHost({
    Map<String, String> environment = const {},
    this.architecture = 'unknown',
    String currentDirectory = '.',
    String temporaryDirectory = '.',
    HostPathsInterface? paths,
    HostProcessInterface? processes,
    HostFileSystemInterface? fileSystem,
  }) : environment = WindowsEnvironment(environment) {
    this.paths =
        paths ??
        WindowsPaths(
          environment: environment,
          currentDirectory: currentDirectory,
          temporaryDirectory: temporaryDirectory,
        );
    this.fileSystem = fileSystem ?? WindowsFileSystem(this.paths);
    this.processes =
        processes ??
        WindowsProcesses(
          paths: this.paths,
          environment: this.environment,
          fileSystem: this.fileSystem,
        );
  }
  @override
  String get name => 'windows';
  @override
  final String architecture;
  @override
  final HostEnvironmentInterface environment;
  @override
  late final HostPathsInterface paths;
  @override
  late final HostProcessInterface processes;
  @override
  late final HostFileSystemInterface fileSystem;
}
