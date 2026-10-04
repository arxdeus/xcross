import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/target/shared/ios_build_platform.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/compose_host.dart';
import 'package:xcross/src/shared/compose/compose_ios_constants.dart';

@internal
abstract interface class ComposeTarget<T extends PlatformHostInterface> {
  IosTarget<T> get target;
  T get host;
  ComposeHost<T> get toolchainHost;
  IosBuildPlatformInterface get buildPlatform;
  String get konanTarget;
  String get gradleTarget;
  String get outputDirectory;
  String get compilerRtName;
  String get targetTriple;
  String get linkerPlatform;
  String? sdkVersion(String sdkPath);
  String runnerDirectory(String projectRoot, String language);
  String generatedRunnerDirectory(String projectRoot);
  List<String> gradleArguments(String kotlinHome);
  Iterable<String> resourceCandidates(String modulePath, String frameworkPath);
  void validateOutput({required bool ipa});
  Future<void> finishBundle(String appPath, ProcessRunner<T> runner);
}

@internal
abstract class BaseComposeTarget<T extends PlatformHostInterface>
    implements ComposeTarget<T> {
  BaseComposeTarget(this.target, this.toolchainHost) {
    if (!identical(target.host, toolchainHost.host)) {
      throw ArgumentError(
        'Compose target and Kotlin toolchain host must share one host instance.',
      );
    }
  }
  @override
  final IosTarget<T> target;
  @override
  final ComposeHost<T> toolchainHost;
  @override
  T get host => target.host;
  @override
  IosBuildPlatformInterface get buildPlatform => target.buildPlatform;
  @override
  String get targetTriple =>
      buildPlatform.buildTriple(composeMinimumIosVersion);
  @override
  String get linkerPlatform => buildPlatform.linkerPlatform;
  @override
  String? sdkVersion(String sdkPath) {
    final name = p.basenameWithoutExtension(sdkPath);
    final prefix = buildPlatform.platformName;
    if (!name.startsWith(prefix)) return null;
    final version = name.substring(prefix.length);
    return version.isEmpty ? null : version;
  }
}

@internal
Iterable<String> primaryResourceCandidates(
  String modulePath,
  String gradleTarget,
) => [
  p.join(
    modulePath,
    'build',
    'kotlin-multiplatform-resources',
    'aggregated-resources',
    gradleTarget,
  ),
  p.join(modulePath, 'build', 'processedResources', gradleTarget, 'main'),
];

@internal
Iterable<String> deviceResourceFallbacks(
  String parent,
  String leaf,
  HostFileSystemInterface files,
) {
  final directory = files.directory(parent);
  if (!directory.existsSync()) return const [];
  final names =
      directory
          .listSync(followLinks: false)
          .whereType<Directory>()
          .map((entity) => p.basename(entity.path))
          .where(isDeviceResourceTarget)
          .toList()
        ..sort();
  return names.map((name) => p.join(parent, name, leaf));
}

@internal
bool isDeviceResourceTarget(String name) {
  final lower = name.toLowerCase();
  return lower.startsWith('ios') &&
      !lower.contains('simulator') &&
      !lower.contains('x64');
}
