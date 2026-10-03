import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/flutter/build/ios_linker_compatibility.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_gate_platform.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/toolchain.dart';

abstract class PosixSwiftPmHostPolicy implements SwiftPmHostPolicy {
  const PosixSwiftPmHostPolicy();
  @override
  String artifactIdentity(String value)=>value;
  @override
  Future<void> stageFlutterFramework<T extends PlatformHostInterface>(SwiftPmFilesystem<T> filesystem, String source, String destination, {bool? copy}) => filesystem.stageFlutterFramework(source, destination, copy: copy ?? false);
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
  List<String> orderInteropTargets(Map<String, dynamic>? dependencies, List<String> targets) =>
      targets;
  @override
  List<String> selectInteropTargets(List<String> planned, Set<String> candidates) => planned.where(candidates.contains).toList();
  

  @override
  Future<String?> cCompiler(
    String sysroot,
    DarwinToolchainResolver toolchain,
  ) async => null;
  @override
  Future<String?> cxxCompiler(
    String sysroot,
    DarwinToolchainResolver toolchain,
  ) async => null;
  @override
  Future<void> configureToolset(
    Map<String, Object> toolset,
    String linker,
    String? cc,
    String? cxx,
    Future<String?> Function(String) resolve,
  ) async {}

  @override
  Map<String, String> bundledToolEnvironment(
    PlatformHostInterface host,
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
  Future<Map<String, Object>>
  buildToolchainIdentity<T extends PlatformHostInterface>(
    SwiftPmToolchain<T> toolchain,
    DarwinSdk? sdk,
  ) => toolchain.sdkIdentity.hostToolchainIdentity();
  @override
  PosixSwiftPmGatePlatform get gatePlatform => const PosixSwiftPmGatePlatform();
}
