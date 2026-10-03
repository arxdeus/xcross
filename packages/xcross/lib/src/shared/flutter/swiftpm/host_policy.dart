import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_platform.dart';
import 'package:xcross/src/shared/flutter/swiftpm/toolchain.dart';

abstract interface class SwiftPmHostPolicy {
  Future<void> stageFlutterFramework<T extends PlatformHostInterface>(SwiftPmFilesystem<T> filesystem, String source, String destination, {bool? copy});
  String artifactIdentity(String value);
  List<String> get packagePrefix;
  List<String> get buildPrefix;
  String get packageTool;
  String get buildTool;
  List<String> get manifestArguments;
  List<String> get buildArguments;
  List<String> get linkerArguments;
  List<String> get fingerprintArguments;
  List<String> get gitConfiguration;
  Map<String, String> get sourceEnvironment;
  
  Future<bool> repairBuildPlan(String scratchPath, String targetBuildDir);
  
  Future<void> rewriteDylib(String path, Set<String> names);
  List<String> orderInteropTargets(Map<String, dynamic>? dependencies, List<String> targets);
  List<String> selectInteropTargets(List<String> planned, Set<String> candidates);
  
  Future<String?> cCompiler(String sysroot, DarwinToolchainResolver toolchain);
  Future<String?> cxxCompiler(
    String sysroot,
    DarwinToolchainResolver toolchain,
  );
  Future<void> configureToolset(
    Map<String, Object> toolset,
    String linker,
    String? cc,
    String? cxx,
    Future<String?> Function(String) resolve,
  );
  bool get captureBuildOutput;

  Map<String, String> bundledToolEnvironment(
    PlatformHostInterface host,
    String executable,
    Map<String, String> environment,
  );
  List<String> linkerPathArguments(String path);
  
  
  
  
  
  
  
  
  
  
  Future<Map<String, Object>> buildToolchainIdentity<
    T extends PlatformHostInterface
  >(SwiftPmToolchain<T> toolchain, DarwinSdk? sdk);
  SwiftPmGatePlatform get gatePlatform;
}
