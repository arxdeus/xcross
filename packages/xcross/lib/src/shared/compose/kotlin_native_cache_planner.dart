import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/build/gradle_klib_builder.dart';
import 'package:xcross/src/shared/compose/build/konan_configuration.dart';
import 'package:xcross/src/shared/compose/klib_manifest.dart';
import 'package:xcross/src/shared/compose/kotlin_native_cache_plan.dart';
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain.dart';

@internal
final class KotlinNativeCachePlanner {
  const KotlinNativeCachePlanner(this.files, this.log);
  final HostFileSystemInterface files;
  final Log log;
  KotlinNativeCachePlan? plan<T extends PlatformHostInterface>({
    required KmpProject project,
    required ComposeToolchain<T> toolchain,
    required PreparedKonanConfiguration prepared,
    required GradleKlibResult klib,
  }) {
    final distribution = p.join(toolchain.kotlinHome, 'klib');
    final platformDir = p.join(
      distribution,
      'platform',
      toolchain.target.konanTarget,
    );
    final cachesDir = p.join(
      project.root,
      'build',
      toolchain.target.outputDirectory,
      'konan-caches',
    );

    final found = <String, KlibManifestNode>{};
    final queue = <String>[];
    void add(String path, {required bool fromDistribution}) {
      final manifest = KlibManifestReader(files).read(path);
      final uniqueName = manifest['unique_name'];
      if (uniqueName == null || found.containsKey(uniqueName)) return;
      final depends = _split(manifest['depends']);
      found[uniqueName] = KlibManifestNode(
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
    queue.addAll(
      _split(KlibManifestReader(files).read(klib.moduleKlibPath)['depends']),
    );
    while (queue.isNotEmpty) {
      final name = queue.removeLast();
      if (found.containsKey(name)) continue;
      final platform = p.join(platformDir, name);
      if (files.directory(platform).existsSync()) {
        add(platform, fromDistribution: true);
      } else {
        log.logTrace('konan cache: no library provides $name; not cached');
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

    if (!toolchain.host.canCacheLibraryNames(found.keys)) {
      log.logTrace(
        'konan cache: disabled, library names are not valid host file names',
      );
      return null;
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
                toolchain.target.konanTarget,
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
      konanTarget: toolchain.target.konanTarget,
      moduleCacheRoot: p.join(cachesDir, 'module-${project.moduleLeaf}'),
    );
  }

  static List<String> _split(String? value) => (value ?? '')
      .split(RegExp(r'\s+'))
      .where((entry) => entry.isNotEmpty)
      .toList();

  /// Cheap change detection: size and mtime of the klib file, or of every
  /// file in an unpacked klib directory (a project dependency is rewritten in
  /// place by Gradle on every change to it).
  String _contentStamp(String path) {
    if (files.file(path).existsSync()) {
      final stat = files.file(path).statSync();
      return '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    }
    final entries =
        files
            .directory(path)
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return entries
        .map((file) {
          final stat = file.statSync();
          return '${p.relative(file.path, from: files.directory(path).path)}:${stat.size}:'
              '${stat.modified.microsecondsSinceEpoch}';
        })
        .join('|');
  }
}

@internal
final class KlibManifestNode {
  const KlibManifestNode(
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
