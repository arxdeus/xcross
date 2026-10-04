import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/shared/errors/errors.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk.dart';
import 'package:darwin_sdk_kit/shared/tbd/tbd_bundle_patch.dart';
import 'package:darwin_sdk_kit/target/shared/ios_build_platform.dart';

final class DarwinSdkRepository<T extends PlatformHostInterface> {
  DarwinSdkRepository(this.host, {required this.log, String? installBundle})
    : installBundle =
          installBundle ??
          host.paths.context.join(
            host.paths.configRoot,
            'xcross',
            'swift-sdks',
            'xcross-darwin.artifactbundle',
          ),
      patch = TbdBundlePatch(host, log: log);
  final T host;
  final Log log;
  final String installBundle;
  final TbdBundlePatch<T> patch;

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
      log.logTrace('DarwinSdk: could not stage runtime layout: $e');
    }
    if (!isValidBundle(candidate)) return null;
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
    if (!backup.existsSync() || !isValidBundle(backup.path)) return;
    try {
      backup.renameSync(bundle);
      log.logWarn('Restored the previous Darwin Swift SDK at $bundle');
    } on FileSystemException catch (error) {
      log.logWarn(
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
  final RegExp _digitPattern = RegExp('[0-9]');

  /// A complete bundle has Swift artifact metadata and a usable iPhoneOS SDK.
  bool isValidBundle(String candidate) {
    const metadata = ['info.json', 'swift-sdk.json', 'toolset.json'];
    if (!metadata.every(
      (n) => host.fileSystem
          .file(host.paths.context.join(candidate, n))
          .existsSync(),
    )) {
      return false;
    }

    try {
      final sdk = _firstSdk(_sdksDir(candidate, 'iPhoneOS'), 'iPhoneOS');
      if (sdk == null) return false;

      final canonicalLayout = _canonicalLayout(candidate);
      final swiftResources = canonicalLayout.parent;
      if (!host.fileSystem
              .directory(
                host.paths.context.join(sdk, 'System', 'Library', 'Frameworks'),
              )
              .existsSync() ||
          !swiftResources.existsSync() ||
          !_hasContent(canonicalLayout) ||
          !_hasContent(_runtimeLayout(candidate))) {
        return false;
      }

      final simulatorPlatform = host.paths.context.join(
        candidate,
        'Developer',
        'Platforms',
        'iPhoneSimulator.platform',
      );
      if ((host.fileSystem.directory(simulatorPlatform).existsSync() ||
              host.fileSystem.file(simulatorPlatform).existsSync() ||
              host.fileSystem.link(simulatorPlatform).existsSync()) &&
          !isValidSimulatorSlice(candidate)) {
        return false;
      }
      final metadata = jsonDecode(
        host.fileSystem
            .file(host.paths.context.join(candidate, 'swift-sdk.json'))
            .readAsStringSync(),
      );
      final targets = metadata is Map ? metadata['targetTriples'] : null;
      if (targets is Map) {
        for (final target in targets.entries) {
          final triple = target.key;
          if (triple is! String ||
              !triple.contains('-apple-ios') ||
              !triple.endsWith('-simulator')) {
            continue;
          }
          if (!isValidSimulatorSlice(candidate)) return false;
          final properties = target.value;
          if (properties is Map &&
              !isValidSimulatorSlice(
                candidate,
                sdkRootPath: properties['sdkRootPath'] is String
                    ? properties['sdkRootPath'] as String
                    : null,
                swiftResourcesPath: properties['swiftResourcesPath'] is String
                    ? properties['swiftResourcesPath'] as String
                    : null,
              )) {
            return false;
          }
        }
      }
      return true;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }

  bool isValidSimulatorSlice(
    String candidate, {
    String? sdkRootPath,
    String? swiftResourcesPath,
  }) {
    try {
      final sdk = sdkRootPath == null
          ? _firstSdk(_sdksDir(candidate, 'iPhoneSimulator'), 'iPhoneSimulator')
          : host.paths.context.join(candidate, sdkRootPath);
      if (sdk == null) return false;
      final resources = swiftResourcesPath == null
          ? _canonicalLayout(candidate).parent.parent.path
          : host.paths.context.join(candidate, swiftResourcesPath);
      return _hasEntries(
            host.fileSystem.directory(
              host.paths.context.join(sdk, 'System', 'Library', 'Frameworks'),
            ),
          ) &&
          _hasEntries(
            host.fileSystem.directory(
              host.paths.context.join(resources, 'iphonesimulator'),
            ),
          );
    } on FileSystemException {
      return false;
    }
  }

  bool _hasEntries(Directory directory) =>
      directory.existsSync() && directory.listSync().isNotEmpty;

  bool _hasContent(File file) => file.existsSync() && file.lengthSync() > 0;

  String iosSdk(DarwinSdk sdk, {required IosBuildPlatformInterface target}) {
    final bundle = sdk.bundle;
    final platform = target.platformName;
    final dir = _sdksDir(bundle, platform);
    final pick = _firstSdk(dir, platform);
    if (pick == null) {
      throw DarwinSdkError(
        'DarwinSdk: Could not find an $platform SDK under $dir.\n'
        'Install one with `xcross sdk install <Xcode.xip|Xcode.app>`.',
      );
    }
    return pick;
  }

  String _sdksDir(String bundle, String platform) => host.paths.context.join(
    bundle,
    'Developer',
    'Platforms',
    '$platform.platform',
    'Developer',
    'SDKs',
  );

  String? _firstSdk(String dir, String prefix) {
    final directory = host.fileSystem.directory(dir);
    if (!directory.existsSync()) return null;
    final names =
        directory
            .listSync()
            .where(
              (entry) =>
                  entry is Directory ||
                  host.fileSystem.directory(entry.path).existsSync(),
            )
            .map((entry) => host.paths.context.basename(entry.path))
            .where((name) => name.startsWith(prefix) && name.endsWith('.sdk'))
            .toList()
          ..sort();

    final pick =
        names.where((name) => name.contains(_digitPattern)).firstOrNull ??
        names.firstOrNull;
    return pick == null ? null : host.paths.context.join(dir, pick);
  }
}
