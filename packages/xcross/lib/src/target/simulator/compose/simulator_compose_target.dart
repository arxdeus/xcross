import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/compose_host.dart';
import 'package:xcross/src/shared/compose/compose_simulator_signing.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/target/shared/compose/compose_target.dart';

@internal
final class SimulatorComposeTarget<T extends PlatformHostInterface>
    extends BaseComposeTarget<T> {
  SimulatorComposeTarget(
    SimulatorTargetInterface<T> target,
    ComposeHost<T> host, {
    required this.signing,
  }) : super(target, host) {
    if (!identical(target.host, signing.host)) {
      throw ArgumentError(
        'Simulator signing capability belongs to another host.',
      );
    }
  }
  final ComposeSimulatorSigning<T> signing;
  @override
  String get konanTarget => 'ios_simulator_arm64';
  @override
  String get gradleTarget => 'iosSimulatorArm64';
  @override
  String get outputDirectory => 'xcross-ios-simulator';
  @override
  String get compilerRtName => 'libclang_rt.iossim.a';
  @override
  String runnerDirectory(String root, String language) => p.join(
    root,
    'build',
    outputDirectory,
    language == 'swift' ? 'swift-runner' : 'runner',
  );
  @override
  String generatedRunnerDirectory(String root) =>
      p.join(root, 'build', outputDirectory, 'Runner');
  @override
  List<String> gradleArguments(String kotlinHome) => [
    '-Pkotlin.native.home=$kotlinHome',
  ];
  @override
  Iterable<String> resourceCandidates(
    String modulePath,
    String frameworkPath,
  ) => primaryResourceCandidates(modulePath, gradleTarget);
  @override
  void validateOutput({required bool ipa}) {
    if (ipa) {
      throw XcrossError('Simulator builds cannot be packaged as an IPA.');
    }
  }

  @override
  Future<void> finishBundle(String appPath, ProcessRunner<T> runner) =>
      signing.signBundle(appPath);
}
