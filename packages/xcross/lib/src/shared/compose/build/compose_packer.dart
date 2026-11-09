import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/build/compose_app_assembler.dart';
import 'package:xcross/src/shared/compose/build/gradle_klib_builder.dart';
import 'package:xcross/src/shared/compose/build/kotlin_framework_builder.dart';
import 'package:xcross/src/shared/compose/build/objc_runner_builder.dart';
import 'package:xcross/src/shared/compose/build/swift_runner_builder.dart';
import 'package:xcross/src/shared/compose/compose_build_context.dart';
import 'package:xcross/src/shared/compose/models/compose_build_options.dart';
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
import 'package:xcross/src/shared/compose/swift/swift_host_paths.dart';
import 'package:xcross/src/shared/compose/swift/swift_import_check.dart';
import 'package:xcross/src/shared/compose/swift/swift_module_index.dart';
import 'package:xcross/src/shared/compose/swiftpm/host_package_link.dart';
import 'package:xcross/src/shared/compose/swiftpm/host_packages_builder.dart';
import 'package:xcross/src/shared/compose/swiftpm/host_swift_packages_reader.dart';
import 'package:xcross/src/shared/compose/swiftpm/swift_package_model.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain_resolver.dart';
import 'package:xcross/src/shared/errors/errors.dart';
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
typedef ComposeBuildSwiftRunner<T extends PlatformHostInterface> =
    Future<String> Function({
      required KmpProject project,
      required String frameworkPath,
      required ComposeToolchain<T> toolchain,
      HostPackageLink? packages,
    });
@internal
typedef ComposeAssembleApp =
    Future<String> Function({
      required KmpProject project,
      required String runnerPath,
      required String frameworkPath,
      HostPackageLink? packages,
    });
@internal
typedef ComposeReadHostPackages =
    HostSwiftPackages Function(KmpProject project);
@internal
typedef ComposeBuildHostPackages<T extends PlatformHostInterface> =
    Future<HostPackageLink> Function({
      required KmpProject project,
      required HostSwiftPackages packages,
      required ComposeToolchain<T> toolchain,
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
    ComposeSwiftPmBuilder<T>? swiftPmBuilder,
  }) : this.withSeams(
         swiftPmBuilder: swiftPmBuilder,
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
    ComposeBuildSwiftRunner<T>? buildSwiftRunner,
    ComposeAssembleApp? assembleApp,
    ComposeSwiftPmBuilder<T>? swiftPmBuilder,
    ComposeReadHostPackages? readHostPackages,
    ComposeBuildHostPackages<T>? buildHostPackages,
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
       _assembleApp = assembleApp,
       _swiftPmBuilder = swiftPmBuilder,
       _readHostPackages = readHostPackages,
       _buildHostPackages = buildHostPackages;

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
  final ComposeBuildSwiftRunner<T>? _buildSwiftRunner;
  final ComposeAssembleApp? _assembleApp;
  final ComposeSwiftPmBuilder<T>? _swiftPmBuilder;
  final ComposeReadHostPackages? _readHostPackages;
  final ComposeBuildHostPackages<T>? _buildHostPackages;

  Future<PackResult> pack() async {
    target.validateOutput(ipa: options.ipa);
    final toolchain = await _resolveToolchain();
    HostPackageLink? packages;
    if (project.entryKind == KmpEntryKind.swiftApp) {
      final declared = readHostPackages();
      checkSwiftImports(toolchain, declared: declared);
      if (!declared.isEmpty) {
        packages = await _buildPackages(toolchain, declared);
        checkBuiltSwiftImports(toolchain, declared, packages);
      }
    }
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
    final appPath = await _buildApp(toolchain, frameworkPath, packages);
    return PackResult(
      outputPath: appPath,
      bundleId: project.bundleId,
      projectRoot: project.root,
    );
  }

  /// The Swift packages the app targets of `iosApp/*.xcodeproj` link.
  HostSwiftPackages readHostPackages() =>
      (_readHostPackages ??
      (project) => readHostSwiftPackages(
        files: runner.host.fileSystem,
        paths: p.context,
        iosAppDir: p.join(project.root, swiftHostDirectory),
      ))(project);

  /// Fails fast, before the network and the slow Kotlin compile, when the
  /// Swift sources import a module that neither the Darwin SDK nor the
  /// [declared] Swift packages can provide. That is only decided here when
  /// the modules of every package are known without building (no packages,
  /// only local ones, or an earlier build already resolved them all).
  /// Otherwise an unknown import may come from a package not fetched yet
  /// (product `FirebaseAnalytics` brings `FirebaseCore`), so it is left to
  /// [checkBuiltSwiftImports], which still runs before Kotlin.
  void checkSwiftImports(
    ComposeToolchain<T> toolchain, {
    HostSwiftPackages declared = HostSwiftPackages.empty,
  }) {
    final known = declaredPackageModules(
      declared,
      runner.host.fileSystem,
      scratchDir: declared.isEmpty ? null : _scratchDir(),
    );
    final missing = unresolvedSwiftImports(
      project,
      _sdkIndex(toolchain, known.modules),
    );
    if (missing.isEmpty) return;
    if (!known.complete) {
      log.logTrace(
        'Swift imports not known before building the Swift packages, '
        'checked after the build: '
        '${missing.map((m) => m.module).toSet().join(', ')}',
      );
      return;
    }
    throw _unresolvedError(toolchain, declared, missing);
  }

  /// After the packages are built, checks every import against the modules
  /// the build actually produced, still before the Kotlin compile.
  void checkBuiltSwiftImports(
    ComposeToolchain<T> toolchain,
    HostSwiftPackages declared,
    HostPackageLink packages,
  ) {
    final missing = unresolvedSwiftImports(
      project,
      _sdkIndex(toolchain, packages.modules),
    );
    if (missing.isEmpty) return;
    throw _unresolvedError(toolchain, declared, missing);
  }

  String? _scratchDir() {
    final builder = _swiftPmBuilder;
    if (builder == null) return null;
    final workspace = builder().workspaceFor(
      project.root,
      environment: runner.effectiveEnvironment,
    );
    return workspace.scratch;
  }

  SwiftModuleIndex _sdkIndex(
    ComposeToolchain<T> toolchain,
    Set<String> packageModules,
  ) => swiftModuleIndexFor(
    files: runner.host.fileSystem,
    sdkPath: toolchain.darwinSdkPath,
    darwinSdkBundle: toolchain.darwinSdkBundle,
    platformSdkName: toolchain.target.buildPlatform.sdkName,
    baseName: project.baseName,
    extraModules: packageModules,
  );

  XcrossError _unresolvedError(
    ComposeToolchain<T> toolchain,
    HostSwiftPackages declared,
    List<UnresolvedSwiftImport> missing,
  ) {
    final lines = formatUnresolvedSwiftImports(project, missing);
    final xcodeproj = declared.xcodeprojPath;
    final relativeProject = xcodeproj == null
        ? null
        : p.isWithin(project.root, xcodeproj)
        ? p.relative(xcodeproj, from: project.root)
        : xcodeproj;
    final sources = declared.isEmpty
        ? 'The Darwin SDK at ${toolchain.darwinSdkPath} does not contain '
              'them, and ${relativeProject == null ? 'no Xcode project in '
                        '$swiftHostDirectory/ declares Swift packages' : '$relativeProject declares no Swift packages'}. '
              'xcross builds the Swift packages the app target of '
              '$swiftHostDirectory/*.xcodeproj depends on; add the package '
              'there.'
        : 'Neither the Darwin SDK at ${toolchain.darwinSdkPath} nor the Swift '
              'packages of $relativeProject provide them. Add the package to '
              'the app target in Xcode.';
    return XcrossError(
      'Swift sources import modules that neither the Darwin SDK nor the '
      'declared Swift packages provide:\n'
      '${lines.join('\n')}\n'
      '$sources CocoaPods are not supported. Wrap optional imports in '
      '`#if canImport(Module)`, or build just the framework with '
      '`xcross compose build --framework`.',
    );
  }

  Future<HostPackageLink> _buildPackages(
    ComposeToolchain<T> toolchain,
    HostSwiftPackages declared,
  ) {
    final count = declared.packages.length;
    return log.logStep(
      'Building Swift packages ($count package${count == 1 ? '' : 's'})',
      () {
        final build = _buildHostPackages;
        if (build != null) {
          return build(
            project: project,
            packages: declared,
            toolchain: toolchain,
          );
        }
        final builder = _swiftPmBuilder;
        if (builder == null) {
          throw StateError(
            'Swift packages need the SwiftPM engine, which this target does '
            'not provide.',
          );
        }
        return HostPackagesBuilder(
          builder: builder(),
          files: runner.host.fileSystem,
          log: log,
        ).build(
          projectRoot: project.root,
          packages: declared,
          platform: toolchain.target.buildPlatform,
          environment: runner.effectiveEnvironment,
        );
      },
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
    HostPackageLink? packages,
  ) async {
    Future<String> buildRunner() {
      switch (project.entryKind) {
        case KmpEntryKind.runnableApp:
          return (_buildObjcRunner ?? ObjcRunnerBuilder(runner).build)(
            project: project,
            frameworkPath: frameworkPath,
            toolchain: toolchain,
          );
        case KmpEntryKind.swiftApp:
          final build = _buildSwiftRunner ?? SwiftRunnerBuilder(runner).build;
          // Without packages, the call (and so the swiftc arguments) is
          // exactly what it was before Swift packages were supported.
          return packages == null
              ? build(
                  project: project,
                  frameworkPath: frameworkPath,
                  toolchain: toolchain,
                )
              : build(
                  project: project,
                  frameworkPath: frameworkPath,
                  toolchain: toolchain,
                  packages: packages,
                );
        case KmpEntryKind.frameworkOnly:
          throw StateError('unreachable');
      }
    }

    final runnerPath = await log.logStep('Compiling Runner', buildRunner);
    final appPath = await log.logStep(
      'Assembling ${project.appName}.app',
      () =>
          (_assembleApp ??
          ComposeAppAssembler(target, runner, log: log).assemble)(
            project: project,
            runnerPath: runnerPath,
            frameworkPath: frameworkPath,
            packages: packages,
          ),
    );
    return appPath;
  }
}
