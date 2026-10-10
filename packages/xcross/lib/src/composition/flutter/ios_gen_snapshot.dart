import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:xcross/src/host/linux/flutter/ios_gen_snapshot_host.dart';
import 'package:xcross/src/host/macos/flutter/ios_gen_snapshot_host.dart';
import 'package:xcross/src/host/shared/flutter/ios_gen_snapshot_host.dart';
import 'package:xcross/src/host/windows/flutter/ios_gen_snapshot_host.dart';
import 'package:xcross/src/shared/config/runtime_config.dart';
import 'package:xcross/src/shared/flutter/build/flutter_aot_snapshotter.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/ios_gen_snapshot_resolver.dart';

/// The iOS AOT compiler source for [host].
@internal
IosGenSnapshotHost composeIosGenSnapshotHost(PlatformHostInterface host) =>
    switch (host) {
      WindowsHostInterface() => WindowsIosGenSnapshotHost(host),
      LinuxHostInterface() => LinuxIosGenSnapshotHost(host),
      MacOSHostInterface() => MacOSIosGenSnapshotHost(host),
      _ => throw UnsupportedError('Unsupported xcross host'),
    };

/// The compiler locator a host context hands to its Flutter build runtimes.
@internal
IosAotCompilerLocator
composeIosAotCompilerLocator<T extends PlatformHostInterface>({
  required ProcessRunner<T> runner,
  required Downloader downloader,
  required http.Client Function() createHttpClient,
  required XcrossRuntimeConfig config,
}) {
  final resolver = _resolver(
    runner: runner,
    downloader: downloader,
    createHttpClient: createHttpClient,
    config: config,
  );
  return ({
    required flutterRoot,
    required engineDirectory,
    required mode,
  }) async => (await resolver.resolve(
    flutterRoot: flutterRoot,
    engineDirectory: engineDirectory,
    mode: mode,
  )).executable;
}

IosGenSnapshotResolver<T> _resolver<T extends PlatformHostInterface>({
  required ProcessRunner<T> runner,
  required Downloader downloader,
  required http.Client Function() createHttpClient,
  required XcrossRuntimeConfig config,
}) => composeIosGenSnapshotResolver(
  runner: runner,
  downloader: downloader,
  createHttpClient: createHttpClient,
  config: config,
);

/// The iOS AOT compiler resolver for [runner]'s host, for commands that
/// inspect or warm the compiler cache outside a build.
@internal
IosGenSnapshotResolver<T>
composeIosGenSnapshotResolver<T extends PlatformHostInterface>({
  required ProcessRunner<T> runner,
  required Downloader downloader,
  required http.Client Function() createHttpClient,
  required XcrossRuntimeConfig config,
}) {
  final host = runner.host;
  return IosGenSnapshotResolver(
    hostPolicy: composeIosGenSnapshotHost(host),
    runner: runner,
    downloader: downloader,
    createHttpClient: createHttpClient,
    cacheRoot: genSnapshotCacheRoot(runner),
    pins: config.config?.iosGenSnapshot ?? const {},
  );
}

/// The xcross cache root iOS AOT compilers live under (as `gen-snapshot/`):
/// `XCROSS_CACHE_DIR` when set, else `<user cache>/xcross`.
@internal
String genSnapshotCacheRoot<T extends PlatformHostInterface>(
  ProcessRunner<T> runner,
) {
  final host = runner.host;
  final override = host.environment.lookup(
    runner.effectiveEnvironment,
    'XCROSS_CACHE_DIR',
  );
  return override != null && override.isNotEmpty
      ? override
      : host.paths.context.join(host.paths.cacheRoot, 'xcross');
}
