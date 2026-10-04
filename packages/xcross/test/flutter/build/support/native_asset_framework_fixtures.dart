import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/flutter/build/internal/native_asset_frameworks.dart';
import 'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart';

import '../../../host_operations_fixtures.dart';

NativeAssetFrameworks<T> nativeFrameworkService<
  T extends PlatformHostInterface
>(ProcessRunner<T> runner) => NativeAssetFrameworks(
  fileSystem: runner.host.fileSystem,
  paths: runner.host.paths.context,
  runner: runner,
  copier: RecursiveDirectoryCopier(
    fileSystem: runner.host.fileSystem,
    paths: runner.host.paths.context,
  ),
);

final class FrameworkLipoProcesses implements HostProcessInterface {
  FrameworkLipoProcesses({required this.fileSystem});

  final HostFileSystemInterface fileSystem;
  final calls = <(String, List<String>, Map<String, String>?)>[];
  int code = 0;
  bool produceOutput = true;
  Exception? startFailure;
  final output = <int>[0xcf, 0xfa, 0xed, 0xfe, 9];

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    calls.add((executable, List.of(arguments), environment));
    final failure = startFailure;
    if (failure != null) throw failure;
    if (produceOutput) {
      await fileSystem.file(arguments.last).writeAsBytes(output);
    }
    return FrameworkLipoChild(code);
  }

  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) async {}

  @override
  Future<String?> findOnShellPath(
    String name, {
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async => null;
}

final class FrameworkLipoChild implements Process {
  FrameworkLipoChild(this.code);
  final int code;
  @override
  int get pid => 42;
  @override
  Future<int> get exitCode async => code;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  IOSink get stdin => fixtureSink();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}
