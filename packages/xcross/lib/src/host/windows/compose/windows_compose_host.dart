import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/build/process_invocation.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/host/shared/compose/posix_compose_host.dart';
import 'package:xcross/src/shared/compose/compose_host.dart';
import 'package:xcross/src/shared/compose/compose_simulator_signing.dart';

final class WindowsComposeHost<T extends WindowsHostInterface>
    implements ComposeHost<T> {
  WindowsComposeHost(this.host, {required this.runningExecutable}) {
    if (!isX64Architecture(host.architecture)) {
      throw XcrossError(
        'Compose Kotlin/Native toolchain supports Windows x64 only; ${host.architecture} is not supported.',
      );
    }
  }
  @override
  ComposeSimulatorSigning<T> simulatorSigning(
    ProcessRunner<T> runner,
  ) => throw XcrossError(
    'Compose iOS simulator builds are supported only on macOS. $classifier toolchains include ios_arm64 device libraries but not ios_simulator_arm64. Use a macOS host for simulator builds or build for an iOS device.',
  );
  @override
  final T host;
  @override
  final String runningExecutable;
  @override
  String get classifier => 'windows-x86_64';
  @override
  String get konanTarget => 'mingw_x64';
  @override
  String hostArtifact(String version) =>
      'kotlin-native-prebuilt-$version-$classifier.zip';
  @override
  List<String> installationArtifacts(String version) => [
    hostArtifact(version),
    'kotlin-native-prebuilt-$version-macos-x86_64.tar.gz',
  ];
  @override
  String konancExecutable(String home) => p.join(home, 'bin', 'konanc.bat');
  @override
  String javaExecutable(String home) => p.join(home, 'bin', 'java.exe');
  @override
  String gradleWrapper(String root) => p.join(root, 'gradlew.bat');
  @override
  bool supportsJavaArchitecture(String architecture) =>
      isX64Architecture(architecture);
  @override
  ProcessInvocation invocation(String executable, List<String> arguments) =>
      ProcessInvocation(executable: executable, arguments: arguments);
  @override
  List<String> compilerArguments(
    List<String> launcher,
    List<String> arguments,
    String Function() writeArgumentFile,
  ) => [...launcher, '@${writeArgumentFile()}'];
  @override
  bool canCacheLibraryNames(Iterable<String> names) => !names.any(
    (name) =>
        RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(name) ||
        name.endsWith('.') ||
        name.endsWith(' '),
  );
  @override
  List<File> shimFingerprintFiles(String runningExecutable) => [
    host.fileSystem.file(runningExecutable),
  ];
  @override
  Future<void> writeShim(
    String path,
    String tool,
    String variable,
    String runningExecutable,
    void Function(String) makeExecutable,
  ) => host.fileSystem.file(runningExecutable).copy(path).then((_) {});
  @override
  String resolveAppleTool(
    String directory,
    String name,
    Iterable<String> searchPath, {
    String? nativeFallback,
  }) => siblingOrOnPath(directory, '$name.exe', searchPath, host.fileSystem);
}
