import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/build/framework_build_stamp.dart';
import 'package:xcross/src/compose/build/gradle_klib_builder.dart';
import 'package:xcross/src/compose/build/konan_configuration.dart';
import 'package:xcross/src/compose/models/compose_build_options.dart';
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/errors.dart';

typedef KotlinNativeRunChecked =
    Future<void> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

typedef PrepareKonanConfiguration =
    Future<PreparedKonanConfiguration> Function({
      required KmpProject project,
      required ComposeToolchain toolchain,
    });

final class KotlinFrameworkBuilder {
  const KotlinFrameworkBuilder() : _runChecked = null, _prepareKonan = null;

  const KotlinFrameworkBuilder.withSeams({
    KotlinNativeRunChecked? runChecked,
    PrepareKonanConfiguration? prepareKonan,
  }) : _runChecked = runChecked,
       _prepareKonan = prepareKonan;

  final KotlinNativeRunChecked? _runChecked;
  final PrepareKonanConfiguration? _prepareKonan;

  Future<String> build({
    required KmpProject project,
    required ComposeBuildOptions options,
    required ComposeToolchain toolchain,
    required GradleKlibResult klib,
  }) async {
    final prepared =
        await (_prepareKonan ?? const KonanConfiguration().prepare)(
          project: project,
          toolchain: toolchain,
        );
    final produced = expectedFramework(project, options.configuration);
    final args = buildKonancArguments(
      project: project,
      options: options,
      klib: klib,
      outputFramework: produced,
    );
    final compilerArgs = [
      '-Xoverride-konan-properties=${prepared.konanPropertyOverrides}',
      ...args,
    ];
    final invocationArgs = toolchain.host.isWindows
        ? [
            ...prepared.compilerArguments,
            '@${_writeArgumentFile(project, options, compilerArgs)}',
          ]
        : [...prepared.compilerArguments, ...compilerArgs];

    // konanc compiles the whole program ahead of time (~133s for the Compose
    // sample), and Gradle's UP-TO-DATE check upstream does not stop us from
    // running it again on identical inputs. Skipping an unchanged compile is
    // what makes `compose run --watch` usable.
    final stampInputs = [klib.moduleKlibPath, ...klib.dependencies];
    final stamp = FrameworkBuildStamp.forFramework(produced);
    if (stamp.isUpToDate(
      frameworkPath: produced,
      inputs: stampInputs,
      arguments: compilerArgs,
    )) {
      Log.logTrace('framework is up to date; skipping konanc');
    } else {
      // Drop the stamp first: a crash or Ctrl-C mid-compile must not leave a
      // stamp that claims the half-written framework is current.
      stamp.invalidate();
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
      'xcross-ios',
      '${project.baseName}.framework',
    );
    final copiedDir = Directory(copied);
    if (copiedDir.existsSync()) copiedDir.deleteSync(recursive: true);
    await _copyDirectory(Directory(produced), copiedDir);
    return copied;
  }

  String _writeArgumentFile(
    KmpProject project,
    ComposeBuildOptions options,
    List<String> arguments,
  ) {
    final path = p.join(
      project.root,
      'build',
      'xcross-ios',
      'konanc-${options.configuration.name}.args',
    );
    final file = File(path)..createSync(recursive: true);
    file.writeAsStringSync('${arguments.map(_quoteArgument).join('\n')}\n');
    return path;
  }

  String _quoteArgument(String argument) =>
      '"${argument.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  List<String> buildKonancArguments({
    required KmpProject project,
    required ComposeBuildOptions options,
    required GradleKlibResult klib,
    required String outputFramework,
  }) {
    final args = <String>[
      '-target',
      'ios_arm64',
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
    ComposeConfiguration configuration,
  ) => p.join(
    project.modulePath,
    'build',
    'bin',
    'iosArm64',
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
    return ProcessRunner.runTool(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
  }

  void _validateFramework(String framework, String baseName) {
    if (!File(p.join(framework, baseName)).existsSync()) {
      throw XcrossError('Kotlin/Native did not produce $baseName.framework.');
    }
    if (!File(p.join(framework, 'Headers', '$baseName.h')).existsSync()) {
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
        await Directory(destination).create(recursive: true);
      } else if (entity is File) {
        await Directory(p.dirname(destination)).create(recursive: true);
        await entity.copy(destination);
      } else {
        throw XcrossError(
          'refusing to copy link from Kotlin framework: ${entity.path}',
        );
      }
    }
  }
}
