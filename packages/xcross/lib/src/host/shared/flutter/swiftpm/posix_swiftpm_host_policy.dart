import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/build/ios_linker_compatibility.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';

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
  bool get captureBuildOutput => false;

  @override
  Future<bool> repairBuildPlan(
    String scratchPath,
    String targetBuildDir,
  ) async => false;

  @override
  List<String> orderInteropTargets(
    Map<String, dynamic>? dependencies,
    List<String> targets,
  ) => targets;
  @override
  List<String> selectInteropTargets(
    List<String> planned,
    Set<String> candidates,
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
}
