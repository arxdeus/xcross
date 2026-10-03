import 'dart:io';
import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/src/darwin_sdk.dart';
import 'package:darwin_sdk_kit/src/tbd_bundle_patch.dart';

final class DarwinSdkRepository<T extends PlatformHostInterface> {
  DarwinSdkRepository(this.host, {String? installBundle})
    : installBundle =
          installBundle ??
          host.paths.context.join(
            host.paths.configRoot,
            'xcross',
            'swift-sdks',
            'xcross-darwin.artifactbundle',
          ),
      patch = TbdBundlePatch(host);
  final T host;
  final String installBundle;
  final TbdBundlePatch<T> patch;
  static bool _hasContent(File file) =>
      file.existsSync() && file.lengthSync() > 0;

  /// Resolve the SDK installed and owned by xcross, or null when incomplete.
  DarwinSdk? current() {
    final candidate = installBundle;
    restoreInterruptedInstall(candidate);
    final source = _canonicalLayout(candidate);
    final destination = _runtimeLayout(candidate);
    try {
      if (!_hasContent(destination) && _hasContent(source)) {
        destination.parent.createSync(recursive: true);
        source.copySync(destination.path);
      }
    } on FileSystemException catch (e) {
      Log.logTrace('DarwinSdk: could not stage runtime layout: $e');
    }
    if (!DarwinSdk.isValidBundle(candidate)) return null;
    // Bundles installed before xcross rewrote text stubs carry architectures
    // no released ld64.lld can parse, which fails every link against them.
    // Repairing on resolve keeps that a one-off scan instead of a
    // multi-gigabyte reinstall; a stamped bundle costs one small file read.
    patch.ensureApplied(candidate);
    return DarwinSdk(candidate);
  }

  /// Where an install keeps the previous [bundle] while publishing its
  /// replacement.
  static String previousInstallPath(String bundle) => '$bundle.previous';

  /// Recover the last working SDK if installation stopped between moving it
  /// aside and publishing the replacement.
  void restoreInterruptedInstall(String bundle) {
    if (host.fileSystem.directory(bundle).existsSync()) return;
    final backup = host.fileSystem.directory(previousInstallPath(bundle));
    if (!backup.existsSync() || !DarwinSdk.isValidBundle(backup.path)) return;
    try {
      backup.renameSync(bundle);
      Log.logWarn('Restored the previous Darwin Swift SDK at $bundle');
    } on FileSystemException catch (error) {
      Log.logWarn(
        'Could not restore the previous Darwin Swift SDK from '
        '${backup.path}: $error',
      );
    }
  }

  File _canonicalLayout(String bundle) => host.fileSystem.file(
    host.paths.context.join(
      bundle,
      'Developer',
      'Toolchains',
      'XcodeDefault.xctoolchain',
      'usr',
      'lib',
      'swift',
      'iphoneos',
      'layouts-arm64.yaml',
    ),
  );

  File _runtimeLayout(String bundle) => host.fileSystem.file(
    host.paths.context.join(
      bundle,
      'Developer',
      'Runtimes',
      'XcodeDefault.xctoolchain',
      'usr',
      'bin',
      'layouts-arm64.yaml',
    ),
  );
}
