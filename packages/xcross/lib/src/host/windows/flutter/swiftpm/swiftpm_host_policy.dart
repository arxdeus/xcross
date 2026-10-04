import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/windows_swift_plan_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_plan.dart'
    show SwiftPmBuildPlan;
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/plan_reader.dart';

final class WindowsSwiftPmHostPolicy implements SwiftPmHostPolicy {
  WindowsSwiftPmHostPolicy(this.runner)
    : repairs = WindowsSwiftPlanRepair(runner);
  final ProcessRunner runner;
  final WindowsSwiftPlanRepair repairs;
  @override
  String artifactIdentity(String value) => value.toLowerCase();

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
  List<String> orderInteropTargets(
    Map<String, dynamic>? dependencies,
    List<String> targets,
  ) => SwiftPmPlanReader.orderTargetsByDependencies(dependencies, targets);
  @override
  List<String> selectInteropTargets(
    List<String> planned,
    Set<String> candidates,
  ) => planned;

  @override
  Map<String, String> bundledToolEnvironment(
    String executable,
    Map<String, String> environment,
  ) {
    final directory = p.dirname(executable);
    if (!runner.host.fileSystem
        .file(p.join(directory, runner.host.paths.executableName('xcrun')))
        .existsSync()) {
      return const {};
    }
    final old = runner.host.environment.lookup(environment, 'PATH');
    return {
      'PATH': runner.host.environment.joinPathList([
        directory,
        if (old != null && old.isNotEmpty)
          ...runner.host.environment.splitPathList(old),
      ]),
    };
  }

  @override
  List<String> linkerPathArguments(String path) => [
    '-Xswiftc',
    '-Xclang-linker',
    '-Xswiftc',
    '--ld-path=$path',
  ];
}
