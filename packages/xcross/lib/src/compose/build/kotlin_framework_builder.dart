import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/build/gradle_klib_builder.dart';
import 'package:xcross/src/compose/build/konan_configuration.dart';
import 'package:xcross/src/compose/build/process_invocation.dart';
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
    final invocation = ProcessInvocation.forHost(
      toolchain.host,
      prepared.konancExecutable,
      args,
    );
    await _run(
      invocation.executable,
      invocation.arguments,
      workingDirectory: project.root,
      environment: prepared.environment,
    );
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
    return ProcessRunner.runChecked(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      inheritStdio: true,
      label: p.basename(executable),
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
