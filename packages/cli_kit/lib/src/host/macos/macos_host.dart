import 'package:cli_kit/src/host/macos/macos_permissions.dart';
import 'package:cli_kit/src/host/shared/native_file_system.dart';
import 'package:cli_kit/src/host/shared/posix_environment.dart';
import 'package:cli_kit/src/host/shared/posix_paths.dart';
import 'package:cli_kit/src/host/shared/posix_processes.dart';
import 'package:cli_kit/src/shared/platform/platform_host.dart';

final class MacOSHost implements MacOSHostInterface {
  MacOSHost({
    Map<String, String> environment = const {},
    this.architecture = 'unknown',
    String currentDirectory = '.',
    String temporaryDirectory = '.',
    HostPathsInterface? paths,
    HostProcessInterface? processes,
    HostFileSystemInterface? fileSystem,
  }) : environment = PosixEnvironment(environment) {
    this.paths =
        paths ??
        PosixPaths(
          environment: environment,
          currentDirectory: currentDirectory,
          temporaryDirectory: temporaryDirectory,
        );
    this.fileSystem =
        fileSystem ??
        NativeFileSystem(this.paths, permissions: MacOSPermissions());
    this.processes = processes ?? PosixProcesses(paths: this.paths);
  }
  @override
  String get name => 'macos';
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
