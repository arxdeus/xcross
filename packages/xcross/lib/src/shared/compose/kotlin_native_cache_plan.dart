import 'package:path/path.dart' as p;

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
    this.konanTarget = 'ios_arm64',
  });

  /// Every library of the link, dependencies before their dependents.
  final List<KlibCacheNode> libraries;

  /// Per-file cache of the module itself, rebuilt for every link.
  final String moduleCacheRoot;
  final String konanTarget;

  List<String> get linkArguments => [
    for (final library in libraries) '-Xcache-directory=${library.cacheRoot}',
    '-Xcache-directory=$moduleCacheRoot',
  ];
}
