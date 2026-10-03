
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/windows_swift_plan_repair.dart';
import 'package:xcross/src/flutter/build/macho_dylib_rewriter.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/gate_platform.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_plan.dart' show SwiftPmBuildPlan;
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/plan_reader.dart';
import 'package:xcross/src/shared/flutter/swiftpm/toolchain.dart';

final class WindowsSwiftPmHostPolicy implements SwiftPmHostPolicy {
  WindowsSwiftPmHostPolicy(this.runner):repairs=WindowsSwiftPlanRepair(runner);
  final ProcessRunner runner;
  final WindowsSwiftPlanRepair repairs;
  @override
  String artifactIdentity(String value)=>value.toLowerCase();
  @override
  Future<void> stageFlutterFramework<T extends PlatformHostInterface>(SwiftPmFilesystem<T> filesystem, String source, String destination, {bool? copy}) => filesystem.stageFlutterFramework(source, destination, copy: copy ?? true);
  @override
  List<String> get packagePrefix => const [];
  @override
  List<String> get buildPrefix => const [];
  @override
  String get packageTool => 'swift-package';
  @override
  String get buildTool => 'swift-build';
  @override
  List<String> get manifestArguments => const [
    '-Xmanifest',
    '-Xfrontend',
    '-Xmanifest',
    '-import-module',
    '-Xmanifest',
    '-Xfrontend',
    '-Xmanifest',
    'CRT',
  ];
  @override
  List<String> get buildArguments => [
    ...manifestArguments,
    '--disable-automatic-resolution',
    '-Xswiftc',
    '-no-verify-emitted-module-interface',
    ...SwiftPmBuildPlan.noImplicitModuleLockArguments,
  ];
  @override
  List<String> get linkerArguments => const [];
  @override
  List<String> get fingerprintArguments => const [];
  @override
  List<String> get gitConfiguration => const ['core.symlinks', 'false'];
  @override
  Map<String, String> get sourceEnvironment => const {
    'EXPERIMENTAL_SPM_BUILDS': '1',
  };
  @override
  bool get captureBuildOutput => runner.log.isVerbose;
  
  @override
  Future<bool> repairBuildPlan(String scratchPath, String targetBuildDir) =>
      repairs.repairWindowsGeneratedBuildFiles(scratchPath, targetBuildDir);
  

  @override
  Future<void> rewriteDylib(String path, Set<String> names) =>
      MachODylibRewriter.rewriteFile(path, producedDylibNames: names);
  @override
  List<String> orderInteropTargets(Map<String, dynamic>? dependencies, List<String> targets) =>
      SwiftPmPlanReader.orderTargetsByDependencies(dependencies, targets);
  @override
  List<String> selectInteropTargets(List<String> planned, Set<String> candidates) => planned;
  

  @override
  Future<String?> cCompiler(
    String sysroot,
    DarwinToolchainResolver toolchain,
  ) => toolchain.resolveDarwinClang(sysroot);
  @override
  Future<String?> cxxCompiler(
    String sysroot,
    DarwinToolchainResolver toolchain,
  ) => toolchain.resolveDarwinClang(sysroot, name: 'clang++');
  @override
  Future<void> configureToolset(
    Map<String, Object> toolset,
    String linker,
    String? cc,
    String? cxx,
    Future<String?> Function(String) resolve,
  ) async {
    for (final entry in {
      'cCompiler': ('clang', cc),
      'cxxCompiler': ('clang++', cxx),
    }.entries) {
      final path = entry.value.$2 ?? await resolve(entry.value.$1);
      if (path == null) throw StateError('Could not find ${entry.value.$1}.');
      toolset[entry.key] = {
        'path': path.replaceAll(r'\', '/'),
        'extraCLIOptions': [r'-fdebug-prefix-map=C:\=/'],
      };
    }
    toolset['linker'] = {
      'path': runner.host.fileSystem.file(linker).resolveSymbolicLinksSync().replaceAll(r'\', '/'),
    };
  }

  @override
  Map<String, String> bundledToolEnvironment(
    PlatformHostInterface host,
    String executable,
    Map<String, String> environment,
  ) {
    final directory = p.dirname(executable);
    if (!runner.host.fileSystem.file(
      p.join(directory, host.paths.executableName('xcrun')),
    ).existsSync()) {
      return const {};
    }
    final old = host.environment.lookup(environment, 'PATH');
    return {
      'PATH': host.environment.joinPathList([
        directory,
        if (old != null && old.isNotEmpty)
          ...host.environment.splitPathList(old),
      ]),
    };
  }

  @override
  List<String> linkerPathArguments(String path) => ['-Xswiftc', '-Xclang-linker', '-Xswiftc', '--ld-path=$path'];
  
  
  

  

  
  
  
  
  

  @override
  Future<Map<String, Object>> buildToolchainIdentity<
    T extends PlatformHostInterface
  >(SwiftPmToolchain<T> toolchain, DarwinSdk? sdk) {
    if (sdk == null) {
      throw FlutterBuildError(
        'Darwin Swift SDK not found. Run `xcross sdk install <Xcode.xip>` first.',
      );
    }
    return toolchain.resolveBuildToolchainIdentity(sdk);
  }


  

  

  @override
  WindowsSwiftPmGatePlatform get gatePlatform =>
      const WindowsSwiftPmGatePlatform();
}
