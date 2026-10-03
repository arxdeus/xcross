import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/target/shared/compose/compose_target.dart';

final class IPhoneComposeTarget<T extends PlatformHostInterface>
    extends BaseComposeTarget<T> {
  IPhoneComposeTarget(IPhoneTargetInterface<T> super.target, super.host);
  @override
  String get konanTarget => 'ios_arm64';
  @override
  String get gradleTarget => 'iosArm64';
  @override
  String get outputDirectory => 'xcross-ios';
  @override
  String get compilerRtName => 'libclang_rt.ios.a';
  @override
  String runnerDirectory(String root, String language) => language == 'swift'
      ? p.join(root, 'build', 'xcross-compose')
      : p.join(root, 'iosApp', '.build', 'runner');
  @override
  String generatedRunnerDirectory(String root) =>
      p.join(root, 'build', 'xcross-compose', 'Runner');
  @override
  List<String> gradleArguments(String kotlinHome) => const [];
  @override
  void validateOutput({required bool ipa}) {}
  @override
  Future<void> finishBundle(String appPath, ProcessRunner<T> runner) async {}
  @override
  Iterable<String> resourceCandidates(
    String modulePath,
    String frameworkPath,
  ) sync* {
    final segments = p.split(frameworkPath);
    final index = segments.indexOf('bin');
    final target =
        index >= 0 &&
            index + 1 < segments.length &&
            isDeviceResourceTarget(segments[index + 1])
        ? segments[index + 1]
        : gradleTarget;
    yield* primaryResourceCandidates(modulePath, target);
    yield* deviceResourceFallbacks(
      p.join(
        modulePath,
        'build',
        'kotlin-multiplatform-resources',
        'aggregated-resources',
      ),
      '',
      host.fileSystem,
    );
    yield* deviceResourceFallbacks(
      p.join(modulePath, 'build', 'processedResources'),
      'main',
      host.fileSystem,
    );
  }
}
