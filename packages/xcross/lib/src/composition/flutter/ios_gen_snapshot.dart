import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/linux/flutter/ios_gen_snapshot_host.dart';
import 'package:xcross/src/host/macos/flutter/ios_gen_snapshot_host.dart';
import 'package:xcross/src/host/shared/flutter/ios_gen_snapshot_host.dart';
import 'package:xcross/src/host/windows/flutter/ios_gen_snapshot_host.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/ios_gen_snapshot_resolver.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';

/// The iOS AOT compiler source for [host].
@internal
IosGenSnapshotHost composeIosGenSnapshotHost(PlatformHostInterface host) =>
    switch (host) {
      WindowsHostInterface() => WindowsIosGenSnapshotHost(host),
      LinuxHostInterface() => LinuxIosGenSnapshotHost(host),
      MacOSHostInterface() => MacOSIosGenSnapshotHost(host),
      _ => throw UnsupportedError('Unsupported xcross host'),
    };

/// Wires an [IosGenSnapshotResolver] from the runtime's host, config pins,
/// downloader, and xcross cache (`XCROSS_CACHE_DIR` or `<cache>/xcross`).
@internal
IosGenSnapshotResolver<T> composeIosGenSnapshotResolver<
  T extends PlatformHostInterface
>(XcrossRuntime<T> runtime) {
  final host = runtime.host;
  final override = host.environment.lookup(
    runtime.runner.effectiveEnvironment,
    'XCROSS_CACHE_DIR',
  );
  return IosGenSnapshotResolver(
    hostPolicy: composeIosGenSnapshotHost(host),
    runner: runtime.runner,
    downloader: runtime.downloader,
    createHttpClient: runtime.createHttpClient,
    cacheRoot: override != null && override.isNotEmpty
        ? override
        : host.paths.context.join(host.paths.cacheRoot, 'xcross'),
    pins: runtime.config.config?.iosGenSnapshot ?? const {},
  );
}
