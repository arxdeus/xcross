import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/build/process_invocation.dart';
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/shared/errors/errors.dart';

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

final class GradleKlibBuilder<T extends PlatformHostInterface> {
  const GradleKlibBuilder(this.runner) : _runChecked = null;

  const GradleKlibBuilder.withSeams(this.runner, {GradleRunChecked? runChecked})
    : _runChecked = runChecked;

  final ProcessRunner<T> runner;
  final GradleRunChecked? _runChecked;

  Future<GradleKlibResult> build({
    required KmpProject project,
    required ComposeToolchain<T> toolchain,
  }) async {
    final gradle = _gradleInvocation(project, toolchain);
    final tmpDir = runner.host.fileSystem
        .directory(runner.host.paths.temporaryRoot)
        .createTempSync('xcross_deps_');
    final depsOutPath = p.join(tmpDir.path, 'iosDeps.txt');
    final initScriptPath = p.join(tmpDir.path, 'dumpDeps.init.gradle.kts');
    final env = <String, String>{
      ...runner.effectiveEnvironment,
      if (toolchain.javaHome.isNotEmpty) 'JAVA_HOME': toolchain.javaHome,
      if (toolchain.konanCache.isNotEmpty)
        'KONAN_DATA_DIR': toolchain.konanCache,
      'XCROSS_DEPS_OUT': depsOutPath,
    };
    if (toolchain.javaHome.isNotEmpty) {
      final parentPath = runner.effectiveEnvironment['PATH'] ?? '';
      final javaBin = p.join(toolchain.javaHome, 'bin');
      env['PATH'] = runner.host.environment.joinPathList([
        javaBin,
        ...runner.host.environment.splitPathList(parentPath),
      ]);
    }

    try {
      // One invocation: dumpIosDeps depends on compileKotlinIosArm64, so
      // Gradle compiles the klib and dumps its dependencies in the same
      // build. Two separate `--no-daemon` builds each paid Gradle's startup
      // and configuration again (over a minute per build on a large project,
      // and on every `compose run --watch` rebuild). The daemon stays allowed
      // for the same reason; Gradle hands it this client's environment
      // (XCROSS_DEPS_OUT, KONAN_DATA_DIR) on every build.
      await runner.host.fileSystem
          .file(initScriptPath)
          .writeAsString(
            _dumpIosDepsInitScript(project, toolchain.target.gradleTarget),
          );
      await _run(
        gradle.executable,
        [
          ...gradle.arguments,
          ':${project.moduleName}:dumpIosDeps',
          '-Pkotlin.native.enableKlibsCrossCompilation=true',
          ...toolchain.target.gradleArguments(toolchain.kotlinHome),
          '-Pxcross.depsOut=$depsOutPath',
          '--init-script',
          initScriptPath,
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
        toolchain.target.gradleTarget,
        'main',
        'klib',
        project.moduleLeaf,
      );
      if ((runner.host.fileSystem.link(moduleKlibPath).existsSync()
              ? FileSystemEntityType.link
              : runner.host.fileSystem.directory(moduleKlibPath).existsSync()
              ? FileSystemEntityType.directory
              : runner.host.fileSystem.file(moduleKlibPath).existsSync()
              ? FileSystemEntityType.file
              : FileSystemEntityType.notFound) ==
          FileSystemEntityType.notFound) {
        throw XcrossError(
          'Gradle did not produce module KLIB at $moduleKlibPath.',
        );
      }
      final depsOut = runner.host.fileSystem.file(depsOutPath);
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
    ComposeToolchain<T> toolchain,
  ) {
    final wrapper = toolchain.host.gradleWrapper(project.root);
    final executable = runner.host.fileSystem.file(wrapper).existsSync()
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
    return runner.runTool(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
  }

  String _dumpIosDepsInitScript(KmpProject project, String target) =>
      '''
allprojects {
    if (path != ":${project.moduleName}") return@allprojects
    tasks.register("dumpIosDeps") {
        dependsOn("compileKotlin${target[0].toUpperCase()}${target.substring(1)}")
        // The app bundle's compose-resources/ is copied from these tasks'
        // outputs. Nothing else runs them, so without this the bundle ships
        // whatever an earlier IDE or Xcode build left there, while the code
        // compiled just now reads string resources at offsets from the
        // current files: a changed strings file aborted the app at launch
        // (Base64 decode failure in getStringItem). Projects without Compose
        // resources do not have the tasks.
        listOf("${target}ProcessResources", "${target}AggregateResources")
            .mapNotNull { project.tasks.findByName(it) }
            .forEach { dependsOn(it) }
        doLast {
            val outPath = (project.findProperty("xcross.depsOut") as String?)
                ?: System.getenv("XCROSS_DEPS_OUT")
                ?: error("XCROSS_DEPS_OUT not set")
            val kotlinExt = project.extensions.findByName("kotlin") ?: error("no kotlin extension")
            val targets = kotlinExt.javaClass.getMethod("getTargets").invoke(kotlinExt)
            val findByName = targets.javaClass.methods.first { it.name == "findByName" }
            val target = findByName.invoke(targets, "$target") ?: error("no $target target")
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
      if (line.isEmpty) continue;
      final normalized = p.normalize(line);
      if (!_isKlib(normalized)) continue;
      if (p.equals(normalized, kotlinRoot) ||
          p.isWithin(kotlinRoot, normalized) ||
          _isDistributionKlib(normalized)) {
        continue;
      }
      if (seen.add(normalized)) dependencies.add(normalized);
    }
    return dependencies;
  }

  /// Whether [path] sits in a Kotlin/Native distribution's `klib/` tree, like
  /// `.../kotlin-native-prebuilt-<host>-<version>/klib/platform/ios_arm64/...`.
  ///
  /// Gradle may resolve its own distribution (under `KONAN_DATA_DIR`), not the
  /// one xcross links with. Its stdlib and platform libraries carry the same
  /// `unique_name`s as the compiler's, and konanc refuses the duplicates.
  static bool _isDistributionKlib(String path) {
    final segments = p.split(path);
    for (var i = 0; i + 1 < segments.length; i++) {
      if (segments[i].startsWith('kotlin-native-prebuilt-') &&
          segments[i + 1] == 'klib') {
        return true;
      }
    }
    return false;
  }

  /// Whether [path] is a KLIB the linker can be handed with `-library`.
  ///
  /// Not an extension test alone: a KLIB is packed as a `.klib` file *or*
  /// unpacked as a directory, and the unpacked form does not have to be named
  /// for it. Project dependencies (`api(project(":core"))`) are the case that
  /// matters - they resolve to
  /// `<module>/build/classes/kotlin/iosArm64/main/klib/core`, an extension-less
  /// directory. Filtering on the suffix dropped them, so the link ran without
  /// the module's own siblings and the compiler failed with errors that name
  /// none of this (`IrCompositeImpl` in `EnumClassLowering`, "no function X in
  /// package Y" during ObjC export).
  ///
  /// An unpacked KLIB is otherwise recognised by its `manifest`, which every
  /// KLIB has: under `default/` in the layout current Kotlin writes, at the root
  /// in the older flat one. That is what makes this a *positive* test, and the
  /// point of it: `compileDependencyFiles` also carries things that are not
  /// libraries at all - the compiler jar among them - and excluding those by
  /// name only works until the next one appears.
  bool _isKlib(String path) {
    if (p.extension(path) == '.klib') {
      return (runner.host.fileSystem.link(path).existsSync()
              ? FileSystemEntityType.link
              : runner.host.fileSystem.directory(path).existsSync()
              ? FileSystemEntityType.directory
              : runner.host.fileSystem.file(path).existsSync()
              ? FileSystemEntityType.file
              : FileSystemEntityType.notFound) !=
          FileSystemEntityType.notFound;
    }
    if (runner.host.fileSystem.directory(path).existsSync()) {
      return runner.host.fileSystem
              .file(p.join(path, 'default', 'manifest'))
              .existsSync() ||
          runner.host.fileSystem.file(p.join(path, 'manifest')).existsSync();
    }
    return false;
  }
}
