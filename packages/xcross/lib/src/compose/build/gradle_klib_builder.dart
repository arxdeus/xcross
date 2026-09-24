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
      ...ProcessRunner.effectiveEnvironment,
      if (toolchain.javaHome.isNotEmpty) 'JAVA_HOME': toolchain.javaHome,
      if (toolchain.konanCache.isNotEmpty)
        'KONAN_DATA_DIR': toolchain.konanCache,
      'XCROSS_DEPS_OUT': depsOutPath,
    };
    if (toolchain.javaHome.isNotEmpty) {
      final parentPath = ProcessRunner.effectiveEnvironment['PATH'] ?? '';
      final javaBin = p.join(toolchain.javaHome, 'bin');
      final pathSeparator = toolchain.host.isWindows ? ';' : ':';
      env['PATH'] = parentPath.isEmpty
          ? javaBin
          : '$javaBin$pathSeparator$parentPath';
    }

    try {
      // One invocation: dumpIosDeps depends on compileKotlinIosArm64, so
      // Gradle compiles the klib and dumps its dependencies in the same
      // build. Two separate `--no-daemon` builds each paid Gradle's startup
      // and configuration again (over a minute per build on a large project,
      // and on every `compose run --watch` rebuild). The daemon stays allowed
      // for the same reason; Gradle hands it this client's environment
      // (XCROSS_DEPS_OUT, KONAN_DATA_DIR) on every build.
      await File(initScriptPath).writeAsString(_dumpIosDepsInitScript(project));
      await _run(
        gradle.executable,
        [
          ...gradle.arguments,
          ':${project.moduleName}:dumpIosDeps',
          '-Pkotlin.native.enableKlibsCrossCompilation=true',
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
    return ProcessRunner.runTool(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
  }

  String _dumpIosDepsInitScript(KmpProject project) =>
      '''
allprojects {
    if (name != "${project.moduleLeaf}") return@allprojects
    tasks.register("dumpIosDeps") {
        dependsOn("compileKotlinIosArm64")
        // The app bundle's compose-resources/ is copied from these tasks'
        // outputs. Nothing else runs them, so without this the bundle ships
        // whatever an earlier IDE or Xcode build left there, while the code
        // compiled just now reads string resources at offsets from the
        // current files: a changed strings file aborted the app at launch
        // (Base64 decode failure in getStringItem). Projects without Compose
        // resources do not have the tasks.
        listOf("iosArm64ProcessResources", "iosArm64AggregateResources")
            .mapNotNull { project.tasks.findByName(it) }
            .forEach { dependsOn(it) }
        doLast {
            val outPath = (project.findProperty("xcross.depsOut") as String?)
                ?: System.getenv("XCROSS_DEPS_OUT")
                ?: error("XCROSS_DEPS_OUT not set")
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
  static bool _isKlib(String path) {
    if (p.extension(path) == '.klib') {
      return FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
    }
    if (FileSystemEntity.isDirectorySync(path)) {
      return File(p.join(path, 'default', 'manifest')).existsSync() ||
          File(p.join(path, 'manifest')).existsSync();
    }
    return false;
  }
}
