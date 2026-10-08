import 'dart:async';
import 'dart:io';

import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/build/gradle_klib_builder.dart';
import 'package:xcross/src/shared/compose/build/konan_configuration.dart';
import 'package:xcross/src/shared/compose/kotlin_native_cache_plan.dart';
import 'package:xcross/src/shared/compose/kotlin_native_cache_planner.dart';
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/shared/errors/errors.dart';

@internal
typedef KotlinNativeCacheRun =
    Future<void> Function(
      String executable,
      List<String> arguments, {
      required String workingDirectory,
      required Map<String, String> environment,
    });

/// One library in the link, with the libraries it depends on.
/// Kotlin/Native compiler caches for debug links.
///
/// Without caches, konanc compiles the module and every dependency into one
/// LLVM module and hands that to a single clang process. For a real Compose
/// app (Compose, Ktor, coroutines, ~140 libraries) that clang process alone
/// reached 11 GB before the kernel killed it. This does what the Kotlin Gradle
/// plugin does on macOS instead:
///
/// * each dependency is compiled once into its own static cache (`-p
///   static_cache`), in dependency order, and reused by every later build
///   until it changes;
/// * the module is compiled into a per-file cache, so no single LLVM module
///   holds more than one source file;
/// * the framework link then only links those caches.
///
/// Measured on a 138-library Compose app: the first build spends ~10 minutes
/// caching dependencies (peak 3.4 GB), after which a changed module builds in
/// ~2.3 minutes with a 3.6 GB peak.
///
/// Release builds never use caches: Kotlin/Native ignores them with `-opt`.
@internal
final class KotlinNativeCaches {
  KotlinNativeCaches({
    required this.files,
    required this.log,
    int? jobs,
    int? backendThreads,
    this.processorCount = 1,
    Map<String, String> environment = const {},
  }) : environment = Map.unmodifiable(environment),
       _jobs = jobs,
       _backendThreads = backendThreads;

  final int processorCount;
  final HostFileSystemInterface files;
  final Log log;
  final Map<String, String> environment;
  final int? _jobs;
  final int? _backendThreads;

  /// Disables caches when set to `1`, as a way out if a cache build breaks.
  static const disableVariable = 'XCROSS_NO_KONAN_CACHE';

  /// How many dependency caches build at once. Each konanc process peaks at
  /// ~3.5 GB on the largest libraries, so the default stays small.
  static const jobsVariable = 'XCROSS_KONAN_CACHE_JOBS';

  static bool enabledIn(Map<String, String> environment) =>
      environment[disableVariable] != '1';

  KotlinNativeCachePlan? plan<T extends PlatformHostInterface>({
    required KmpProject project,
    required ComposeToolchain<T> toolchain,
    required PreparedKonanConfiguration prepared,
    required GradleKlibResult klib,
  }) => KotlinNativeCachePlanner(files, log).plan(
    project: project,
    toolchain: toolchain,
    prepared: prepared,
    klib: klib,
  );

  /// Builds every missing dependency cache, then the module's per-file cache.
  Future<void> build({
    required KotlinNativeCachePlan plan,
    required PreparedKonanConfiguration prepared,
    required GradleKlibResult klib,
    required String workingDirectory,
    required KotlinNativeCacheRun run,
  }) async {
    final byName = {for (final node in plan.libraries) node.uniqueName: node};
    final missing = plan.libraries
        .where((node) => !_isComplete(node.cacheRoot))
        .toList();
    if (missing.isNotEmpty) {
      log.logTrace(
        'konan cache: building ${missing.length} of '
        '${plan.libraries.length} dependency caches',
      );
    }
    await _runInDependencyOrder(missing, (node) async {
      final transitive = _transitive(node, byName);
      final staging = '${node.cacheRoot}.staging.$pid';
      final stagingDir = files.directory(staging);
      if (stagingDir.existsSync()) stagingDir.deleteSync(recursive: true);
      stagingDir.createSync(recursive: true);
      await run(
        prepared.javaExecutable,
        [
          ...prepared.compilerArguments,
          ..._common(prepared, plan.konanTarget),
          '-p',
          'static_cache',
          '-Xadd-cache=${node.path}',
          '-Xcache-directory=$staging',
          for (final dependency in transitive) ...[
            if (!dependency.fromDistribution) ...['-library', dependency.path],
            '-Xcached-library=${dependency.path},${dependency.cachePath}',
          ],
        ],
        workingDirectory: workingDirectory,
        environment: prepared.environment,
      );
      if (!files
          .directory(p.join(staging, '${node.uniqueName}-cache'))
          .existsSync()) {
        throw XcrossError(
          'Kotlin/Native did not produce a cache for ${node.uniqueName}. '
          'Set ${KotlinNativeCaches.disableVariable}=1 to build without '
          'caches.',
        );
      }
      files.file(p.join(staging, _completeMarker)).writeAsStringSync(node.path);
      final target = files.directory(node.cacheRoot);
      if (target.existsSync()) target.deleteSync(recursive: true);
      stagingDir.renameSync(files.directory(node.cacheRoot).path);
    });

    _pruneStale(plan);

    final moduleDir = files.directory(plan.moduleCacheRoot);
    if (moduleDir.existsSync()) moduleDir.deleteSync(recursive: true);
    moduleDir.createSync(recursive: true);
    await run(
      prepared.javaExecutable,
      [
        ...prepared.compilerArguments,
        ..._common(prepared, plan.konanTarget),
        '-p',
        'static_cache',
        '-Xadd-cache=${klib.moduleKlibPath}',
        '-Xmake-per-file-cache',
        '-Xbackend-threads=$_threads',
        '-Xcache-directory=${plan.moduleCacheRoot}',
        for (final node in plan.libraries)
          '-Xcache-directory=${node.cacheRoot}',
        for (final dependency in klib.dependencies) ...['-library', dependency],
      ],
      workingDirectory: workingDirectory,
      environment: prepared.environment,
    );
  }

  List<String> _common(
    PreparedKonanConfiguration prepared,
    String konanTarget,
  ) => [
    '-Xoverride-konan-properties=${prepared.konanPropertyOverrides}',
    '-target',
    konanTarget,
    // Same reason as the framework link (see KotlinFrameworkBuilder): the
    // assertion fires for any Apple target on a non-Apple host, and cache
    // builds do not inherit it from anywhere.
    '-Xbinary=enableDebugTransparentStepping=false',
  ];

  int get _threads => _backendThreads ?? (processorCount ~/ 2).clamp(1, 4);

  int get _parallelJobs {
    final configured = int.tryParse(environment[jobsVariable] ?? '');
    return _jobs ??
        (configured != null && configured > 0 ? configured : null) ??
        (processorCount ~/ 4).clamp(1, 2);
  }

  Future<void> _runInDependencyOrder(
    List<KlibCacheNode> nodes,
    Future<void> Function(KlibCacheNode node) build,
  ) async {
    final pending = [...nodes];
    final waitingOn = {for (final node in nodes) node.uniqueName};
    final running = <String, Future<String>>{};
    while (pending.isNotEmpty || running.isNotEmpty) {
      for (final node in [...pending]) {
        if (running.length >= _parallelJobs) break;
        if (node.dependencies.any(waitingOn.contains)) continue;
        pending.remove(node);
        running[node.uniqueName] = build(node).then((_) => node.uniqueName);
      }
      if (running.isEmpty) {
        throw StateError('dependency cycle among ${pending.length} klibs');
      }
      final done = await Future.any(running.values);
      // Already complete; awaiting it only drops the entry.
      await running.remove(done);
      waitingOn.remove(done);
    }
  }

  static List<KlibCacheNode> _transitive(
    KlibCacheNode node,
    Map<String, KlibCacheNode> byName,
  ) {
    final seen = <String>{};
    final result = <KlibCacheNode>[];
    void walk(KlibCacheNode current) {
      for (final name in current.dependencies) {
        final dependency = byName[name];
        if (dependency == null || !seen.add(name)) continue;
        walk(dependency);
        result.add(dependency);
      }
    }

    walk(node);
    return result;
  }

  /// Removes completed caches the current plan no longer uses, so every
  /// dependency or compiler change does not leave its old caches behind.
  void _pruneStale(KotlinNativeCachePlan plan) {
    final live = {
      for (final node in plan.libraries) p.normalize(node.cacheRoot),
    };
    final root = files.directory(p.dirname(plan.moduleCacheRoot));
    if (!root.existsSync()) return;
    for (final entry in root.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (name.startsWith('module-') || name.contains('.staging.')) continue;
      if (live.contains(p.normalize(entry.path))) continue;
      if (!_isComplete(entry.path)) continue;
      try {
        entry.deleteSync(recursive: true);
      } on FileSystemException catch (error) {
        log.logTrace('konan cache: could not prune ${entry.path}: $error');
      }
    }
  }

  bool _isComplete(String cacheRoot) =>
      files.file(p.join(cacheRoot, _completeMarker)).existsSync();

  static const _completeMarker = '.xcross-complete';
}
