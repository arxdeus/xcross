import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/build/process_invocation.dart';
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/errors.dart';

typedef GradleRunChecked =
    Future<void> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

final class GradleKlibResult {
  const GradleKlibResult({
    required this.moduleKlibPath,
    required this.dependencies,
  });

  final String moduleKlibPath;
  final List<String> dependencies;
}

final class GradleKlibBuilder {
  const GradleKlibBuilder() : _runChecked = null;

  const GradleKlibBuilder.withSeams({GradleRunChecked? runChecked})
    : _runChecked = runChecked;

  final GradleRunChecked? _runChecked;

  Future<GradleKlibResult> build({
    required KmpProject project,
    required ComposeToolchain toolchain,
  }) async {
    final gradle = _gradleInvocation(project, toolchain);
    final tmpDir = Directory.systemTemp.createTempSync('xcross_deps_');
    final depsOutPath = p.join(tmpDir.path, 'iosDeps.txt');
    final initScriptPath = p.join(tmpDir.path, 'dumpDeps.init.gradle.kts');
    final env = <String, String>{
      ...Platform.environment,
      if (toolchain.javaHome.isNotEmpty) 'JAVA_HOME': toolchain.javaHome,
      if (toolchain.konanCache.isNotEmpty)
        'KONAN_DATA_DIR': toolchain.konanCache,
      'XCROSS_DEPS_OUT': depsOutPath,
    };
    if (toolchain.javaHome.isNotEmpty) {
      final parentPath = Platform.environment['PATH'] ?? '';
      final javaBin = p.join(toolchain.javaHome, 'bin');
      final pathSeparator = toolchain.host.isWindows ? ';' : ':';
      env['PATH'] = parentPath.isEmpty
          ? javaBin
          : '$javaBin$pathSeparator$parentPath';
    }

    try {
      await _run(
        gradle.executable,
        [
          ...gradle.arguments,
          ':${project.moduleName}:compileKotlinIosArm64',
          '-Pkotlin.native.enableKlibsCrossCompilation=true',
          '--no-daemon',
          '--console=plain',
        ],
        workingDirectory: project.root,
        environment: env,
      );

      await File(initScriptPath).writeAsString(_dumpIosDepsInitScript(project));
      await _run(
        gradle.executable,
        [
          ...gradle.arguments,
          ':${project.moduleName}:dumpIosDeps',
          '--init-script',
          initScriptPath,
          '--no-daemon',
          '--no-configuration-cache',
          '--console=plain',
        ],
        workingDirectory: project.root,
        environment: env,
      );

      final moduleKlibPath = p.join(
        project.modulePath,
        'build',
        'classes',
        'kotlin',
        'iosArm64',
        'main',
        'klib',
        project.moduleLeaf,
      );
      if (FileSystemEntity.typeSync(moduleKlibPath) ==
          FileSystemEntityType.notFound) {
        throw XcrossError(
          'Gradle did not produce module KLIB at $moduleKlibPath.',
        );
      }
      final depsOut = File(depsOutPath);
      if (!depsOut.existsSync()) {
        throw XcrossError(
          'Gradle dependency output not found at $depsOutPath.',
        );
      }
      return GradleKlibResult(
        moduleKlibPath: moduleKlibPath,
        dependencies: _dependencies(
          depsOut.readAsStringSync(),
          toolchain.kotlinHome,
        ),
      );
    } finally {
      try {
        if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  ProcessInvocation _gradleInvocation(
    KmpProject project,
    ComposeToolchain toolchain,
  ) {
    final wrapperName = toolchain.host.isWindows ? 'gradlew.bat' : 'gradlew';
    final wrapper = p.join(project.root, wrapperName);
    final executable = File(wrapper).existsSync()
        ? wrapper
        : toolchain.gradleExecutable;
    return ProcessInvocation.forHost(toolchain.host, executable, const []);
  }

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

  String _dumpIosDepsInitScript(KmpProject project) =>
      '''
allprojects {
    if (name != "${project.moduleLeaf}") return@allprojects
    tasks.register("dumpIosDeps") {
        dependsOn("compileKotlinIosArm64")
        doLast {
            val outPath = System.getenv("XCROSS_DEPS_OUT") ?: error("XCROSS_DEPS_OUT not set")
            val kotlinExt = project.extensions.findByName("kotlin") ?: error("no kotlin extension")
            val targets = kotlinExt.javaClass.getMethod("getTargets").invoke(kotlinExt)
            val findByName = targets.javaClass.methods.first { it.name == "findByName" }
            val target = findByName.invoke(targets, "iosArm64") ?: error("no iosArm64 target")
            val compilations = target.javaClass.getMethod("getCompilations").invoke(target)
            val getByName = compilations.javaClass.methods.first { it.name == "getByName" && it.parameterCount == 1 }
            val main = getByName.invoke(compilations, "main")
            val cdf = main.javaClass.methods.first { it.name == "getCompileDependencyFiles" }.invoke(main)
            @Suppress("UNCHECKED_CAST")
            val files = cdf.javaClass.getMethod("getFiles").invoke(cdf) as Set<java.io.File>
            java.io.File(outPath).writeText(files.joinToString("\\n") { it.absolutePath })
        }
    }
}
''';

  List<String> _dependencies(String output, String kotlinHome) {
    final kotlinRoot = p.normalize(kotlinHome);
    final seen = <String>{};
    final dependencies = <String>[];
    for (final rawLine in output.split('\n')) {
      final line = rawLine.trim();
      if (!line.endsWith('.klib')) continue;
      final normalized = p.normalize(line);
      if (FileSystemEntity.typeSync(normalized) ==
          FileSystemEntityType.notFound) {
        continue;
      }
      if (p.equals(normalized, kotlinRoot) ||
          p.isWithin(kotlinRoot, normalized)) {
        continue;
      }
      if (seen.add(normalized)) dependencies.add(normalized);
    }
    return dependencies;
  }
}
