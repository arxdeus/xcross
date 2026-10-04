import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/build/framework_build_stamp.dart';
import 'package:xcross/src/shared/compose/build/gradle_klib_builder.dart';
import 'package:xcross/src/shared/compose/build/konan_configuration.dart';
import 'package:xcross/src/shared/compose/build/kotlin_native_caches.dart';
import 'package:xcross/src/shared/compose/models/compose_build_options.dart';
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/target/shared/compose/compose_target.dart';

typedef KotlinNativeRunChecked =
    Future<void> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

typedef PrepareKonanConfiguration<T extends PlatformHostInterface> =
    Future<PreparedKonanConfiguration> Function({
      required KmpProject project,
      required ComposeToolchain<T> toolchain,
    });

final class KotlinFrameworkBuilder<T extends PlatformHostInterface> {
  KotlinFrameworkBuilder(
    this.runner, {
    required this.log,
    required int processorCount,
  }) : _runChecked = null,
       _prepareKonan = null,
       _caches = KotlinNativeCaches(
         files: runner.host.fileSystem,
         processorCount: processorCount,
         log: log,
         environment: runner.effectiveEnvironment,
       );

  /// [caches] is off unless given: a seam-built builder links the way it
  /// always has, in one konanc call.
  const KotlinFrameworkBuilder.withSeams(
    this.runner, {
    required this.log,
    KotlinNativeRunChecked? runChecked,
    PrepareKonanConfiguration<T>? prepareKonan,
    KotlinNativeCaches? caches,
  }) : _runChecked = runChecked,
       _prepareKonan = prepareKonan,
       _caches = caches;

  final ProcessRunner<T> runner;
  final Log log;
  final KotlinNativeRunChecked? _runChecked;
  final PrepareKonanConfiguration<T>? _prepareKonan;
  final KotlinNativeCaches? _caches;

  Future<String> build({
    required KmpProject project,
    required ComposeBuildOptions options,
    required ComposeToolchain<T> toolchain,
    required GradleKlibResult klib,
  }) async {
    final prepared =
        await (_prepareKonan ?? KonanConfiguration(runner).prepare)(
          project: project,
          toolchain: toolchain,
        );
    final produced = expectedFramework(
      project,
      options.configuration,
      target: toolchain.target,
    );
    final args = buildKonancArguments(
      project: project,
      options: options,
      target: toolchain.target,
      klib: klib,
      outputFramework: produced,
    );
    final caches = _caches;
    final cachePlan =
        caches != null &&
            options.configuration == ComposeConfiguration.debug &&
            KotlinNativeCaches.enabledIn(runner.effectiveEnvironment)
        ? caches.plan(
            project: project,
            toolchain: toolchain,
            prepared: prepared,
            klib: klib,
          )
        : null;
    final compilerArgs = [
      '-Xoverride-konan-properties=${prepared.konanPropertyOverrides}',
      ...args,
      // Cache directories are content-keyed, so they also make the stamp
      // below notice a dependency or compiler change.
      ...?cachePlan?.linkArguments,
    ];
    final invocationArgs = toolchain.host.compilerArguments(
      prepared.compilerArguments,
      compilerArgs,
      () =>
          _writeArgumentFile(project, options, toolchain.target, compilerArgs),
    );

    // konanc compiles the whole program ahead of time (~133s for the Compose
    // sample), and Gradle's UP-TO-DATE check upstream does not stop us from
    // running it again on identical inputs. Skipping an unchanged compile is
    // what makes `compose run --watch` usable.
    final stampInputs = [klib.moduleKlibPath, ...klib.dependencies];
    final stamp = FrameworkBuildStamp.forFramework(
      produced,
      files: runner.host.fileSystem,
    );
    if (stamp.isUpToDate(
      frameworkPath: produced,
      inputs: stampInputs,
      arguments: compilerArgs,
    )) {
      log.logTrace('framework is up to date; skipping konanc');
    } else {
      // Drop the stamp first: a crash or Ctrl-C mid-compile must not leave a
      // stamp that claims the half-written framework is current.
      stamp.invalidate();
      if (cachePlan != null) {
        await caches!.build(
          plan: cachePlan,
          prepared: prepared,
          klib: klib,
          workingDirectory: project.root,
          run: _run,
        );
      }
      await _run(
        prepared.javaExecutable,
        invocationArgs,
        workingDirectory: project.root,
        environment: prepared.environment,
      );
      _validateFramework(produced, project.baseName);
      stamp.write(inputs: stampInputs, arguments: compilerArgs);
    }
    _validateFramework(produced, project.baseName);
    final copied = p.join(
      project.root,
      'build',
      toolchain.target.outputDirectory,
      '${project.baseName}.framework',
    );
    final copiedDir = runner.host.fileSystem.directory(copied);
    if (copiedDir.existsSync()) copiedDir.deleteSync(recursive: true);
    await _copyDirectory(runner.host.fileSystem.directory(produced), copiedDir);
    return copied;
  }

  String _writeArgumentFile(
    KmpProject project,
    ComposeBuildOptions options,
    ComposeTarget<T> target,
    List<String> arguments,
  ) {
    final path = p.join(
      project.root,
      'build',
      target.outputDirectory,
      'konanc-${options.configuration.name}.args',
    );
    final file = runner.host.fileSystem.file(path)..createSync(recursive: true);
    file.writeAsStringSync('${arguments.map(_quoteArgument).join('\n')}\n');
    return path;
  }

  String _quoteArgument(String argument) =>
      '"${argument.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  List<String> buildKonancArguments({
    required KmpProject project,
    required ComposeBuildOptions options,
    required ComposeTarget<T> target,
    required GradleKlibResult klib,
    required String outputFramework,
  }) {
    final args = <String>[
      '-target',
      target.konanTarget,
      '-produce',
      'framework',
      '-Xinclude=${klib.moduleKlibPath}',
      '-Xbinary=bundleId=${options.bundleId ?? project.bundleId}',
      // Kotlin/Native's DICreateFunctionShared() asserts(false) when asked
      // for transparent-stepping debug info on a host whose LLVM wasn't
      // built with __APPLE__ defined (see DebugInfoC.cpp). The compiler
      // enables this by default for any Apple-family *target* regardless
      // of host, which crashes cross-compilation from Linux/Windows hosts.
      // xcross only ever cross-compiles from non-Apple hosts, so it is
      // always safe to disable it here.
      '-Xbinary=enableDebugTransparentStepping=false',
      // KGP passes this for `binaries.framework { isStatic = true }`. Without
      // it a static-framework project gets a dynamic library, whose link must
      // resolve every ObjC dependency (FirebaseMessaging, sqlite3, …) instead
      // of leaving them to the app's own link step.
      if (project.isStaticFramework) '-Xstatic-framework',
    ];
    for (final dependency in klib.dependencies) {
      args.addAll(['-library', dependency]);
    }
    if (options.configuration == ComposeConfiguration.release) args.add('-opt');
    args.addAll(['-o', outputFramework]);
    return args;
  }

  String expectedFramework(
    KmpProject project,
    ComposeConfiguration configuration, {
    required ComposeTarget<T> target,
  }) => p.join(
    project.modulePath,
    'build',
    'bin',
    target.gradleTarget,
    configuration == ComposeConfiguration.release
        ? 'releaseFramework'
        : 'debugFramework',
    '${project.baseName}.framework',
  );

  Future<void> _run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
  }) {
    final runChecked = _runChecked;
    if (runChecked != null) {
      return runChecked(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );
    }
    return runner.runTool(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
  }

  void _validateFramework(String framework, String baseName) {
    if (!runner.host.fileSystem
        .file(p.join(framework, baseName))
        .existsSync()) {
      throw XcrossError('Kotlin/Native did not produce $baseName.framework.');
    }
    if (!runner.host.fileSystem
        .file(p.join(framework, 'Headers', '$baseName.h'))
        .existsSync()) {
      throw XcrossError(
        'Kotlin/Native did not produce $baseName.framework headers.',
      );
    }
  }

  Future<void> _copyDirectory(Directory source, Directory target) async {
    if (!source.existsSync()) {
      throw XcrossError(
        'Kotlin/Native did not produce ${p.basename(source.path)}.',
      );
    }
    await target.create(recursive: true);
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      final relative = p.relative(entity.path, from: source.path);
      final destination = p.join(target.path, relative);
      if (entity is Directory) {
        await runner.host.fileSystem
            .directory(destination)
            .create(recursive: true);
      } else if (entity is File) {
        await runner.host.fileSystem
            .directory(p.dirname(destination))
            .create(recursive: true);
        await entity.copy(runner.host.fileSystem.file(destination).path);
      } else {
        throw XcrossError(
          'refusing to copy link from Kotlin framework: ${entity.path}',
        );
      }
    }
  }
}
