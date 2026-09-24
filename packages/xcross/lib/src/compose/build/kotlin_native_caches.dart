import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/build/gradle_klib_builder.dart';
import 'package:xcross/src/compose/build/konan_configuration.dart';
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/errors.dart';

typedef KotlinNativeCacheRun =
    Future<void> Function(
      String executable,
      List<String> arguments, {
      required String workingDirectory,
      required Map<String, String> environment,
    });

/// One library in the link, with the libraries it depends on.
final class KlibCacheNode {
  const KlibCacheNode({
    required this.uniqueName,
    required this.path,
    required this.dependencies,
    required this.cacheRoot,
    required this.fromDistribution,
  });

  /// `unique_name` from the klib manifest, unescaped. Kotlin/Native names the
  /// cache it produces for this library `<uniqueName>-cache`.
  final String uniqueName;
  final String path;

  /// Unique names of this library's direct dependencies that are in the plan.
  final List<String> dependencies;

  /// Directory holding this library's cache. Its name is a content key, so a
  /// changed library (or a changed dependency, or compiler) gets a new one.
  final String cacheRoot;

  /// stdlib and platform libraries: the compiler resolves those from its own
  /// distribution, so they are never passed with `-library`.
  final bool fromDistribution;

  String get cachePath => p.join(cacheRoot, '$uniqueName-cache');
}

final class KotlinNativeCachePlan {
  const KotlinNativeCachePlan({
    required this.libraries,
    required this.moduleCacheRoot,
  });

  /// Every library of the link, dependencies before their dependents.
  final List<KlibCacheNode> libraries;

  /// Per-file cache of the module itself, rebuilt for every link.
  final String moduleCacheRoot;

  List<String> get linkArguments => [
    for (final library in libraries) '-Xcache-directory=${library.cacheRoot}',
    '-Xcache-directory=$moduleCacheRoot',
  ];
}

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
final class KotlinNativeCaches {
  const KotlinNativeCaches({int? jobs, int? backendThreads})
    : _jobs = jobs,
      _backendThreads = backendThreads;

  final int? _jobs;
  final int? _backendThreads;

  /// Disables caches when set to `1`, as a way out if a cache build breaks.
  static const disableVariable = 'XCROSS_NO_KONAN_CACHE';

  /// How many dependency caches build at once. Each konanc process peaks at
  /// ~3.5 GB on the largest libraries, so the default stays small.
  static const jobsVariable = 'XCROSS_KONAN_CACHE_JOBS';

  static bool enabledIn(Map<String, String> environment) =>
      environment[disableVariable] != '1';

  KotlinNativeCachePlan? plan({
    required KmpProject project,
    required ComposeToolchain toolchain,
    required PreparedKonanConfiguration prepared,
    required GradleKlibResult klib,
  }) {
    final distribution = p.join(toolchain.kotlinHome, 'klib');
    final platformDir = p.join(distribution, 'platform', 'ios_arm64');
    final cachesDir = p.join(
      project.root,
      'build',
      'xcross-ios',
      'konan-caches',
    );

    final found = <String, _Klib>{};
    final queue = <String>[];
    void add(String path, {required bool fromDistribution}) {
      final manifest = readKlibManifest(path);
      final uniqueName = manifest['unique_name'];
      if (uniqueName == null || found.containsKey(uniqueName)) return;
      final depends = _split(manifest['depends']);
      found[uniqueName] = _Klib(
        uniqueName,
        path,
        depends,
        fromDistribution: fromDistribution,
      );
      queue.addAll(depends);
    }

    add(p.join(distribution, 'common', 'stdlib'), fromDistribution: true);
    for (final dependency in klib.dependencies) {
      add(dependency, fromDistribution: false);
    }
    // The module's own manifest names the platform libraries it uses
    // directly; those must be cached too or the module cache is refused
    // ("is going to be cached, but its dependency isn't").
    queue.addAll(_split(readKlibManifest(klib.moduleKlibPath)['depends']));
    while (queue.isNotEmpty) {
      final name = queue.removeLast();
      if (found.containsKey(name)) continue;
      final platform = p.join(platformDir, name);
      if (FileSystemEntity.isDirectorySync(platform)) {
        add(platform, fromDistribution: true);
      } else {
        Log.logTrace('konan cache: no library provides $name; not cached');
      }
    }

    final order = <String>[];
    final visiting = <String>{};
    void visit(String name) {
      if (order.contains(name) || !visiting.add(name)) return;
      for (final dependency in found[name]!.depends) {
        if (found.containsKey(dependency)) visit(dependency);
      }
      order.add(name);
    }

    for (final name in found.keys.toList()..sort()) {
      visit(name);
    }

    if (toolchain.host.isWindows) {
      final unsafe = found.keys.where(_unsafeWindowsName).toList()..sort();
      if (unsafe.isNotEmpty) {
        Log.logTrace(
          'konan cache: disabled, library names are not valid Windows '
          'file names: ${unsafe.join(', ')}',
        );
        return null;
      }
    }

    final compiler = p.basename(p.dirname(prepared.kotlinHome));
    final keys = <String, String>{};
    final nodes = <KlibCacheNode>[];
    for (final name in order) {
      final library = found[name]!;
      final dependencies = library.depends.where(found.containsKey).toList();
      final key = sha256
          .convert(
            utf8.encode(
              [
                compiler,
                library.path,
                _contentStamp(library.path),
                for (final dependency in dependencies) keys[dependency],
              ].join('\u0000'),
            ),
          )
          .toString()
          .substring(0, 24);
      keys[name] = key;
      nodes.add(
        KlibCacheNode(
          uniqueName: name,
          path: library.path,
          dependencies: dependencies,
          cacheRoot: p.join(cachesDir, key),
          fromDistribution: library.fromDistribution,
        ),
      );
    }
    return KotlinNativeCachePlan(
      libraries: nodes,
      moduleCacheRoot: p.join(cachesDir, 'module-${project.moduleLeaf}'),
    );
  }

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
      Log.logTrace(
        'konan cache: building ${missing.length} of '
        '${plan.libraries.length} dependency caches',
      );
    }
    await _runInDependencyOrder(missing, (node) async {
      final transitive = _transitive(node, byName);
      final staging = '${node.cacheRoot}.staging.$pid';
      final stagingDir = Directory(staging);
      if (stagingDir.existsSync()) stagingDir.deleteSync(recursive: true);
      stagingDir.createSync(recursive: true);
      await run(
        prepared.javaExecutable,
        [
          ...prepared.compilerArguments,
          ..._common(prepared),
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
      if (!Directory(
        p.join(staging, '${node.uniqueName}-cache'),
      ).existsSync()) {
        throw XcrossError(
          'Kotlin/Native did not produce a cache for ${node.uniqueName}. '
          'Set ${KotlinNativeCaches.disableVariable}=1 to build without '
          'caches.',
        );
      }
      File(p.join(staging, _completeMarker)).writeAsStringSync(node.path);
      final target = Directory(node.cacheRoot);
      if (target.existsSync()) target.deleteSync(recursive: true);
      stagingDir.renameSync(node.cacheRoot);
    });

    _pruneStale(plan);

    final moduleDir = Directory(plan.moduleCacheRoot);
    if (moduleDir.existsSync()) moduleDir.deleteSync(recursive: true);
    moduleDir.createSync(recursive: true);
    await run(
      prepared.javaExecutable,
      [
        ...prepared.compilerArguments,
        ..._common(prepared),
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

  static bool _unsafeWindowsName(String name) =>
      RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(name) ||
      name.endsWith('.') ||
      name.endsWith(' ');

  List<String> _common(PreparedKonanConfiguration prepared) => [
    '-Xoverride-konan-properties=${prepared.konanPropertyOverrides}',
    '-target',
    'ios_arm64',
    // Same reason as the framework link (see KotlinFrameworkBuilder): the
    // assertion fires for any Apple target on a non-Apple host, and cache
    // builds do not inherit it from anywhere.
    '-Xbinary=enableDebugTransparentStepping=false',
  ];

  int get _threads =>
      _backendThreads ?? (Platform.numberOfProcessors ~/ 2).clamp(1, 4);

  int get _parallelJobs {
    final configured = int.tryParse(
      ProcessRunner.effectiveEnvironment[jobsVariable] ?? '',
    );
    return _jobs ??
        (configured != null && configured > 0 ? configured : null) ??
        (Platform.numberOfProcessors ~/ 4).clamp(1, 2);
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
  static void _pruneStale(KotlinNativeCachePlan plan) {
    final live = {
      for (final node in plan.libraries) p.normalize(node.cacheRoot),
    };
    final root = Directory(p.dirname(plan.moduleCacheRoot));
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
        Log.logTrace('konan cache: could not prune ${entry.path}: $error');
      }
    }
  }

  static bool _isComplete(String cacheRoot) =>
      File(p.join(cacheRoot, _completeMarker)).existsSync();

  static const _completeMarker = '.xcross-complete';

  static List<String> _split(String? value) => (value ?? '')
      .split(RegExp(r'\s+'))
      .where((entry) => entry.isNotEmpty)
      .toList();

  /// Cheap change detection: size and mtime of the klib file, or of every
  /// file in an unpacked klib directory (a project dependency is rewritten in
  /// place by Gradle on every change to it).
  static String _contentStamp(String path) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.file) {
      final stat = File(path).statSync();
      return '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    }
    final files =
        Directory(path)
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return files
        .map((file) {
          final stat = file.statSync();
          return '${p.relative(file.path, from: path)}:${stat.size}:'
              '${stat.modified.microsecondsSinceEpoch}';
        })
        .join('|');
  }
}

/// Reads the manifest of a packed (`.klib`) or unpacked klib.
///
/// Only the manifest entry is decompressed; Compose's klibs are tens of MB.
Map<String, String> readKlibManifest(String path) {
  String? text;
  if (FileSystemEntity.isFileSync(path)) {
    final input = InputFileStream(path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      for (final entry in archive) {
        if (entry.isFile &&
            (entry.name == 'default/manifest' || entry.name == 'manifest')) {
          text = utf8.decode(entry.readBytes()!);
          break;
        }
      }
    } finally {
      input.closeSync();
    }
  } else {
    for (final candidate in [
      p.join(path, 'default', 'manifest'),
      p.join(path, 'manifest'),
    ]) {
      final file = File(candidate);
      if (file.existsSync()) {
        text = file.readAsStringSync();
        break;
      }
    }
  }
  if (text == null) throw XcrossError('No klib manifest in $path.');
  return parseJavaProperties(text);
}

/// `java.util.Properties` text format, as far as klib manifests use it:
/// `key=value` or `key: value` lines, `#`/`!` comments, backslash escapes
/// (`unique_name=org.jetbrains.kotlinx\:kotlinx-io-core`) and continuation
/// lines.
Map<String, String> parseJavaProperties(String text) {
  final result = <String, String>{};
  final lines = const LineSplitter().convert(text);
  var index = 0;
  while (index < lines.length) {
    var line = lines[index++].trimLeft();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('!')) continue;
    while (_continues(line) && index < lines.length) {
      line = line.substring(0, line.length - 1) + lines[index++].trimLeft();
    }
    final key = StringBuffer();
    var position = 0;
    while (position < line.length) {
      final char = line[position];
      if (char == r'\' && position + 1 < line.length) {
        key.write(_unescape(line[position + 1]));
        position += 2;
        continue;
      }
      if (char == '=' || char == ':' || char == ' ' || char == '\t') break;
      key.write(char);
      position++;
    }
    while (position < line.length && ' \t'.contains(line[position])) {
      position++;
    }
    if (position < line.length && '=:'.contains(line[position])) position++;
    while (position < line.length && ' \t'.contains(line[position])) {
      position++;
    }
    final value = StringBuffer();
    while (position < line.length) {
      final char = line[position];
      if (char == r'\' && position + 1 < line.length) {
        value.write(_unescape(line[position + 1]));
        position += 2;
        continue;
      }
      value.write(char);
      position++;
    }
    result[key.toString()] = value.toString();
  }
  return result;
}

bool _continues(String line) {
  var slashes = 0;
  for (var i = line.length - 1; i >= 0 && line[i] == r'\'; i--) {
    slashes++;
  }
  return slashes.isOdd;
}

String _unescape(String char) => switch (char) {
  't' => '\t',
  'n' => '\n',
  'r' => '\r',
  'f' => '\f',
  _ => char,
};

final class _Klib {
  const _Klib(
    this.uniqueName,
    this.path,
    this.depends, {
    required this.fromDistribution,
  });

  final String uniqueName;
  final String path;
  final List<String> depends;
  final bool fromDistribution;
}
