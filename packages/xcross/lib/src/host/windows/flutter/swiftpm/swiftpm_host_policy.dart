import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/host/windows/flutter/swiftpm/windows_swift_plan_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_plan.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_compiler.dart';
import 'package:xcross/src/shared/sdk/swift_environment_host.dart';

@internal
final class WindowsSwiftPmHostPolicy implements SwiftPmHostPolicy {
  WindowsSwiftPmHostPolicy(this.runner, {required this.swiftEnvironment})
    : repairs = WindowsSwiftPlanRepair(runner);
  final ProcessRunner runner;
  final SwiftEnvironmentHostInterface swiftEnvironment;
  final WindowsSwiftPlanRepair repairs;
  @override
  Future<Map<String, String>> hostEnvironment() =>
      swiftEnvironment.swiftEnvironment();
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
  List<String> selectInteropTargets(
    List<String> planned,
    Set<String> candidates,
    Set<String>? consumed,
  ) => consumed == null
      ? planned
      : planned
            .where(
              (target) =>
                  candidates.contains(target) || consumed.contains(target),
            )
            .toList();

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

  @override
  Future<String> installManifestCompiler(
    PlatformHostInterface host, {
    required String directory,
    required String executable,
    required String configuration,
  }) async {
    final shim = p.windows.join(directory, '$manifestCompilerName.exe');
    await host.fileSystem
        .directory(host.paths.ioPath(directory))
        .create(recursive: true);
    await writeManifestCompilerFile(host, '$shim.policy.json', configuration);
    await copyManifestCompilerExecutable(host, executable, shim);
    return shim;
  }
}
