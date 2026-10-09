import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/composition/flutter/ios_gen_snapshot.dart';
import 'package:xcross/src/shared/cli/basic/cache_command.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';

/// `xcross cache` wired to the runtime's cache roots and Flutter SDKs.
@internal
CacheCommand composeCacheCommand<T extends PlatformHostInterface>(
  XcrossRuntime<T> runtime,
) {
  final host = runtime.host;
  final paths = host.paths.context;
  return CacheCommand(
    CachePruneCommand(
      host: host,
      log: runtime.log,
      engineRoot: paths.join(host.paths.cacheRoot, 'xcross', 'flutter-engine'),
      genSnapshotRoot: paths.join(
        genSnapshotCacheRoot(runtime.runner),
        'gen-snapshot',
      ),
      inUseEngines: () => discoverFlutterEngines(runtime),
    ),
  );
}

/// Engine revisions of every Flutter SDK this machine points xcross at:
/// `roots.flutterSdk` and `tools.flutter` from xcross config, `FLUTTER_ROOT`,
/// and the `flutter` on `PATH`. Projects pinned through `.fvm` are not
/// visible from here, which is why prune also requires an age limit.
@internal
Future<Set<String>> discoverFlutterEngines<T extends PlatformHostInterface>(
  XcrossRuntime<T> runtime,
) async {
  final host = runtime.host;
  final paths = host.paths.context;
  final roots = <String>{};
  void addRoot(String? root) {
    if (root != null && root.trim().isNotEmpty) roots.add(root.trim());
  }

  String? rootOfExecutable(String executable) {
    try {
      final file = host.fileSystem.file(executable);
      final resolved = file.existsSync()
          ? file.resolveSymbolicLinksSync()
          : executable;
      return paths.dirname(paths.dirname(resolved));
    } on Object {
      return null;
    }
  }

  addRoot(runtime.config.roots?.flutterSdk);
  addRoot(
    runtime.runner.environmentValue(
      runtime.runner.effectiveEnvironment,
      'FLUTTER_ROOT',
    ),
  );
  final configuredTool = runtime.config.tools['flutter'];
  if (configuredTool != null) addRoot(rootOfExecutable(configuredTool));
  try {
    final onPath = await runtime.runner.which('flutter');
    if (onPath != null) addRoot(rootOfExecutable(onPath));
  } on Object {
    // No flutter on PATH is a normal state, not an error.
  }
  return {for (final root in roots) ?flutterEngineRevision(host, root)};
}
