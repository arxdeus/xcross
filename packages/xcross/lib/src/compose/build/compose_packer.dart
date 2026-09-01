import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/compose/build/compose_app_assembler.dart';
import 'package:xcross/src/compose/build/gradle_klib_builder.dart';
import 'package:xcross/src/compose/build/kotlin_framework_builder.dart';
import 'package:xcross/src/compose/build/objc_runner_builder.dart';
import 'package:xcross/src/compose/build/swift_runner_builder.dart';
import 'package:xcross/src/compose/models/compose_build_options.dart';
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/compose/toolchain/compose_host.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain_resolver.dart';
import 'package:xcross/src/models/pack_result.dart';

typedef ComposeCurrentHost = ComposeHost Function();
typedef ComposeEnvironment = Map<String, String> Function();
typedef ComposeEnsureToolchain =
    Future<ComposeToolchain> Function({
      required ComposeHost host,
      required Map<String, String> environment,
      required String projectRoot,
      required bool allowInstall,
      required bool force,
    });
typedef ComposeBuildKlib =
    Future<GradleKlibResult> Function({
      required KmpProject project,
      required ComposeToolchain toolchain,
    });
typedef ComposeBuildFramework =
    Future<String> Function({
      required KmpProject project,
      required ComposeBuildOptions options,
      required ComposeToolchain toolchain,
      required GradleKlibResult klib,
    });
typedef ComposeBuildObjcRunner =
    Future<String> Function({
      required KmpProject project,
      required String frameworkPath,
      required ComposeToolchain toolchain,
    });
typedef ComposeBuildSwiftRunner =
    Future<String> Function({
      required KmpProject project,
      required String frameworkPath,
      required ComposeToolchain toolchain,
    });
typedef ComposeAssembleApp =
    Future<String> Function({
      required KmpProject project,
      required String runnerPath,
      required String frameworkPath,
    });

final class ComposePacker {
  ComposePacker({
    required KmpProject project,
    required ComposeBuildOptions options,
  }) : this.withSeams(project: project, options: options);

  const ComposePacker.withSeams({
    required this.project,
    required this.options,
    ComposeCurrentHost? currentHost,
    ComposeEnvironment? environment,
    ComposeEnsureToolchain? ensureToolchain,
    ComposeBuildKlib? buildKlib,
    ComposeBuildFramework? buildFramework,
    ComposeBuildObjcRunner? buildObjcRunner,
    ComposeBuildSwiftRunner? buildSwiftRunner,
    ComposeAssembleApp? assembleApp,
  }) : _currentHost = currentHost,
       _environment = environment,
       _ensureToolchain = ensureToolchain,
       _buildKlib = buildKlib,
       _buildFramework = buildFramework,
       _buildObjcRunner = buildObjcRunner,
       _buildSwiftRunner = buildSwiftRunner,
       _assembleApp = assembleApp;

  final KmpProject project;
  final ComposeBuildOptions options;
  final ComposeCurrentHost? _currentHost;
  final ComposeEnvironment? _environment;
  final ComposeEnsureToolchain? _ensureToolchain;
  final ComposeBuildKlib? _buildKlib;
  final ComposeBuildFramework? _buildFramework;
  final ComposeBuildObjcRunner? _buildObjcRunner;
  final ComposeBuildSwiftRunner? _buildSwiftRunner;
  final ComposeAssembleApp? _assembleApp;

  /// Build the project, reporting each stage as its own phase.
  ///
  /// Every stage shells out to a build tool that narrates itself at length —
  /// Gradle alone prints a screenful of task lines per run. Naming the stages
  /// here is what lets [ProcessRunner.runTool] collapse all of that into one
  /// spinner per stage, and keeps the raw logs one `--verbose` away.
  Future<PackResult> pack() async {
    final toolchain = await Log.logStep(
      'Resolving toolchain',
      () => (_ensureToolchain ?? _defaultEnsureToolchain)(
        host: (_currentHost ?? ComposeHost.current)(),
        environment:
            (_environment ?? (() => ProcessRunner.effectiveEnvironment))(),
        projectRoot: project.root,
        allowInstall: true,
        force: false,
      ),
    );
    final klib = await Log.logStep(
      'Compiling Kotlin sources',
      () => (_buildKlib ?? _defaultBuildKlib)(
        project: project,
        toolchain: toolchain,
      ),
    );
    final frameworkPath = await Log.logStep(
      'Building ${project.baseName}.framework',
      () => (_buildFramework ?? _defaultBuildFramework)(
        project: project,
        options: options,
        toolchain: toolchain,
        klib: klib,
      ),
    );

    if (project.entryKind == KmpEntryKind.frameworkOnly) {
      return PackResult(
        outputPath: frameworkPath,
        bundleId: project.bundleId,
        kind: PackOutputKind.framework,
        projectRoot: project.root,
      );
    }

    final runnerPath = await Log.logStep(
      'Compiling Runner',
      () => switch (project.entryKind) {
        KmpEntryKind.runnableApp =>
          (_buildObjcRunner ?? _defaultBuildObjcRunner)(
            project: project,
            frameworkPath: frameworkPath,
            toolchain: toolchain,
          ),
        KmpEntryKind.swiftApp =>
          (_buildSwiftRunner ?? _defaultBuildSwiftRunner)(
            project: project,
            frameworkPath: frameworkPath,
            toolchain: toolchain,
          ),
        KmpEntryKind.frameworkOnly => throw StateError('unreachable'),
      },
    );
    final appPath = await Log.logStep(
      'Assembling ${project.appName}.app',
      () => (_assembleApp ?? _defaultAssembleApp)(
        project: project,
        runnerPath: runnerPath,
        frameworkPath: frameworkPath,
      ),
    );
    return PackResult(
      outputPath: appPath,
      bundleId: project.bundleId,
      projectRoot: project.root,
    );
  }

  static Future<ComposeToolchain> _defaultEnsureToolchain({
    required ComposeHost host,
    required Map<String, String> environment,
    required String projectRoot,
    required bool allowInstall,
    required bool force,
  }) => ComposeToolchainResolver.ensure(
    host: host,
    environment: environment,
    projectRoot: projectRoot,
    allowInstall: allowInstall,
    force: force,
  );

  static Future<GradleKlibResult> _defaultBuildKlib({
    required KmpProject project,
    required ComposeToolchain toolchain,
  }) => const GradleKlibBuilder().build(project: project, toolchain: toolchain);

  static Future<String> _defaultBuildFramework({
    required KmpProject project,
    required ComposeBuildOptions options,
    required ComposeToolchain toolchain,
    required GradleKlibResult klib,
  }) => const KotlinFrameworkBuilder().build(
    project: project,
    options: options,
    toolchain: toolchain,
    klib: klib,
  );

  static Future<String> _defaultBuildObjcRunner({
    required KmpProject project,
    required String frameworkPath,
    required ComposeToolchain toolchain,
  }) => ObjcRunnerBuilder().build(
    project: project,
    frameworkPath: frameworkPath,
    toolchain: toolchain,
  );

  static Future<String> _defaultBuildSwiftRunner({
    required KmpProject project,
    required String frameworkPath,
    required ComposeToolchain toolchain,
  }) => SwiftRunnerBuilder().build(
    project: project,
    frameworkPath: frameworkPath,
    toolchain: toolchain,
  );

  static Future<String> _defaultAssembleApp({
    required KmpProject project,
    required String runnerPath,
    required String frameworkPath,
  }) => ComposeAppAssembler.assemble(
    project: project,
    runnerPath: runnerPath,
    frameworkPath: frameworkPath,
  );
}
