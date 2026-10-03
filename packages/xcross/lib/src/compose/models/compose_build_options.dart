import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';

enum ComposeConfiguration { debug, release }

final class ComposeBuildOptions {
  const ComposeBuildOptions({
    this.configuration = ComposeConfiguration.debug,
    this.bundleId,
    this.appName,
    this.ipa = false,
    this.simulator = false,
  });

  final ComposeConfiguration configuration;
  final String? bundleId;
  final String? appName;
  final bool ipa;
  final bool simulator;

  String get konanTarget => simulator ? 'ios_simulator_arm64' : 'ios_arm64';
  String get gradleTarget => simulator ? 'iosSimulatorArm64' : 'iosArm64';
  String get outputDirectory =>
      simulator ? 'xcross-ios-simulator' : 'xcross-ios';
  IosTarget get iosTarget => simulator ? IosTarget.simulator : IosTarget.device;
  String get targetTriple => iosTarget.buildTriple('15.0');
  String get linkerPlatform => iosTarget.linkerPlatform;
}
