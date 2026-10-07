import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/compose/build/compose_app_assembler.dart';
import 'package:xcross/src/shared/compose/build/gradle_klib_builder.dart';
import 'package:xcross/src/shared/compose/build/kotlin_framework_builder.dart';
import 'package:xcross/src/shared/compose/build/objc_runner_builder.dart';
import 'package:xcross/src/shared/compose/build/swift_runner_builder.dart';
import 'package:xcross/src/shared/compose/compose_build_context.dart';
import 'package:xcross/src/shared/compose/models/compose_build_options.dart';
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain_resolver.dart';
import 'package:xcross/src/shared/models/pack_result.dart';
import 'package:xcross/src/target/shared/compose/compose_target.dart';

@internal
typedef ComposeEnsureToolchain<T extends PlatformHostInterface> =
    Future<ComposeToolchain<T>> Function({
      required Map<String, String> environment,
      required String projectRoot,
      required bool allowInstall,
      required bool force,
    });
@internal
typedef ComposeBuildKlib<T extends PlatformHostInterface> =
    Future<GradleKlibResult> Function({
      required KmpProject project,
      required ComposeToolchain<T> toolchain,
    });
@internal
typedef ComposeBuildFramework<T extends PlatformHostInterface> =
    Future<String> Function({
      required KmpProject project,
      required ComposeBuildOptions options,
      required ComposeToolchain<T> toolchain,
      required GradleKlibResult klib,
    });
@internal
typedef ComposeBuildRunner<T extends PlatformHostInterface> =
    Future<String> Function({
      required KmpProject project,
      required String frameworkPath,
      required ComposeToolchain<T> toolchain,
    });
@internal
typedef ComposeAssembleApp =
    Future<String> Function({
      required KmpProject project,
      required String runnerPath,
      required String frameworkPath,
    });

@internal
final class ComposePacker<T extends PlatformHostInterface> {
  ComposePacker({
    required KmpProject project,
    required ComposeBuildOptions options,
    required ComposeTarget<T> target,
    required ProcessRunner<T> runner,
    required Log log,
    required Downloader downloader,
    required DarwinToolchainResolver<T> tools,
    required DarwinSdkRepository<T> sdkRepository,
    String? cacheRoot,
    int processorCount = 1,
  }) : this.withSeams(
         project: project,
         options: options,
         target: target,
         runner: runner,
         log: log,
         downloader: downloader,
         tools: tools,
         sdkRepository: sdkRepository,
         cacheRoot: cacheRoot,
         processorCount: processorCount,
       );

  ComposePacker.withSeams({
    required this.project,
    required this.options,
    required ComposeTarget<T> target,
    required ProcessRunner<T> runner,
    required DarwinToolchainResolver<T> tools,
    required DarwinSdkRepository<T> sdkRepository,
    required Log log,
    required Downloader downloader,
    String? cacheRoot,
    int processorCount = 1,
    ComposeEnsureToolchain<T>? ensureToolchain,
    ComposeBuildKlib<T>? buildKlib,
    ComposeBuildFramework<T>? buildFramework,
    ComposeBuildRunner<T>? buildObjcRunner,
    ComposeBuildRunner<T>? buildSwiftRunner,
    ComposeAssembleApp? assembleApp,
  }) : context = ComposeBuildContext(
         target: target,
         runner: runner,
         tools: tools,
         sdkRepository: sdkRepository,
         log: log,
         downloader: downloader,
         cacheRoot: cacheRoot,
         processorCount: processorCount,
       ),
       _ensureToolchain = ensureToolchain,
       _buildKlib = buildKlib,
       _buildFramework = buildFramework,
       _buildObjcRunner = buildObjcRunner,
       _buildSwiftRunner = buildSwiftRunner,
       _assembleApp = assembleApp;

  final KmpProject project;
  final ComposeBuildOptions options;
  final ComposeBuildContext<T> context;
  ComposeTarget<T> get target => context.target;
  ProcessRunner<T> get runner => context.runner;
  DarwinToolchainResolver<T> get tools => context.tools;
  DarwinSdkRepository<T> get sdkRepository => context.sdkRepository;
  Log get log => context.log;
  int get processorCount => context.processorCount;
  Downloader get downloader => context.downloader;
  String? get _cacheRoot => context.cacheRoot;
  final ComposeEnsureToolchain<T>? _ensureToolchain;
  final ComposeBuildKlib<T>? _buildKlib;
  final ComposeBuildFramework<T>? _buildFramework;
  final ComposeBuildRunner<T>? _buildObjcRunner;
  final ComposeBuildRunner<T>? _buildSwiftRunner;
  final ComposeAssembleApp? _assembleApp;

  Future<PackResult> pack() async {
    target.validateOutput(ipa: options.ipa);
    final toolchain = await _resolveToolchain();
    final klib = await log.logStep(
      'Compiling Kotlin sources',
      () => (_buildKlib ?? GradleKlibBuilder(runner).build)(
        project: project,
        toolchain: toolchain,
      ),
    );
    final frameworkPath = await _compileFramework(toolchain, klib);
    if (project.entryKind == KmpEntryKind.frameworkOnly) {
      return PackResult(
        outputPath: frameworkPath,
        bundleId: project.bundleId,
        kind: PackOutputKind.framework,
        projectRoot: project.root,
      );
    }
    final appPath = await _buildApp(toolchain, frameworkPath);
    return PackResult(
      outputPath: appPath,
      bundleId: project.bundleId,
      projectRoot: project.root,
    );
  }

  Future<ComposeToolchain<T>> _resolveToolchain() async {
    final resolver = ComposeToolchainResolver(
      target,
      runner: runner,
      log: log,
      downloader: downloader,
      tools: tools,
      sdkRepository: sdkRepository,
      cacheRoot: _cacheRoot,
    );
    final toolchain = await log.logStep(
      'Resolving toolchain',
      () => (_ensureToolchain ?? resolver.ensure)(
        environment: runner.effectiveEnvironment,
        projectRoot: project.root,
        allowInstall: true,
        force: false,
      ),
    );
    if (!identical(toolchain.target, target)) {
      throw StateError(
        'Resolved Compose toolchain must retain its build target.',
      );
    }
    return toolchain;
  }

  Future<String> _compileFramework(
    ComposeToolchain<T> toolchain,
    GradleKlibResult klib,
  ) async {
    final frameworkPath = await log.logStep(
      'Building ${project.baseName}.framework',
      () =>
          (_buildFramework ??
          KotlinFrameworkBuilder(
            runner,
            log: log,
            processorCount: processorCount,
          ).build)(
            project: project,
            options: options,
            toolchain: toolchain,
            klib: klib,
          ),
    );
    return frameworkPath;
  }

  Future<String> _buildApp(
    ComposeToolchain<T> toolchain,
    String frameworkPath,
  ) async {
    final buildRunner = switch (project.entryKind) {
      KmpEntryKind.runnableApp =>
        _buildObjcRunner ?? ObjcRunnerBuilder(runner).build,
      KmpEntryKind.swiftApp =>
        _buildSwiftRunner ?? SwiftRunnerBuilder(runner).build,
      KmpEntryKind.frameworkOnly => throw StateError('unreachable'),
    };
    final runnerPath = await log.logStep(
      'Compiling Runner',
      () => buildRunner(
        project: project,
        frameworkPath: frameworkPath,
        toolchain: toolchain,
      ),
    );
    final appPath = await log.logStep(
      'Assembling ${project.appName}.app',
      () =>
          (_assembleApp ??
          ComposeAppAssembler(target, runner, log: log).assemble)(
            project: project,
            runnerPath: runnerPath,
            frameworkPath: frameworkPath,
          ),
    );
    return appPath;
  }
}
