import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_templates_posix.dart';
import 'package:xcross/src/shared/flutter/build/ios_linker_compatibility.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_compiler.dart';

@internal
abstract class PosixSwiftPmHostPolicy implements SwiftPmHostPolicy {
  const PosixSwiftPmHostPolicy();
  @override
  String artifactIdentity(String value) => value;

  @override
  List<String> get packagePrefix => const ['package'];
  @override
  List<String> get buildPrefix => const ['build'];
  @override
  String get packageTool => 'swift';
  @override
  String get buildTool => 'swift';
  @override
  List<String> get manifestArguments => const [];
  @override
  List<String> get buildArguments => const [];
  @override
  List<String> get linkerArguments => objectiveCSmallStubSwiftDriverArguments;
  @override
  List<String> get fingerprintArguments => const [];
  @override
  List<String> get gitConfiguration => const [];
  @override
  Map<String, String> get sourceEnvironment => const {};
  @override
  Future<Map<String, String>> hostEnvironment() async => const {};
  @override
  bool get captureBuildOutput => false;
  @override
  bool get warmsImplicitModules => false;

  @override
  Future<bool> repairBuildPlan(
    String scratchPath,
    String targetBuildDir,
  ) async => false;

  @override
  List<String> selectInteropTargets(
    List<String> planned,
    Set<String> candidates,
    Set<String>? consumed,
  ) => planned.where(candidates.contains).toList();

  @override
  Map<String, String> bundledToolEnvironment(
    String executable,
    Map<String, String> environment,
  ) => const {};
  @override
  List<String> linkerPathArguments(String path) => [
    '-Xswiftc',
    '-Xclang-linker',
    '-Xswiftc',
    '--ld-path=$path',
  ];

  @override
  Future<String> installManifestCompiler(
    PlatformHostInterface host, {
    required String directory,
    required String executable,
    required String configuration,
  }) async {
    final paths = host.paths.context;
    final shim = paths.join(directory, manifestCompilerName);
    final sidecar = '$shim.policy.json';
    final script =
        '#!/bin/sh\n'
        '$manifestCompilerVariable=${shellQuote(sidecar)}\n'
        'export $manifestCompilerVariable\n'
        'exec ${shellQuote(executable)} "\$@"\n';
    await host.fileSystem.directory(directory).create(recursive: true);
    await writeManifestCompilerFile(host, sidecar, configuration);
    await writeManifestCompilerFile(host, shim, script);
    host.fileSystem.makeExecutable(shim);
    return shim;
  }
}
