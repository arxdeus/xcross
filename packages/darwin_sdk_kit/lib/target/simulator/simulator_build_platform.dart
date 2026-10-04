import 'package:darwin_sdk_kit/target/shared/ios_build_platform.dart';

final class SimulatorBuildPlatform implements IosBuildPlatformInterface {
  const SimulatorBuildPlatform();
  @override
  String get sdkName => 'iphonesimulator';
  @override
  String get platformName => 'iPhoneSimulator';
  @override
  String get swiftSdkTriple => 'arm64-apple-ios-simulator';
  @override
  String get linkerPlatform => 'ios-simulator';
  @override
  String buildTriple(String minimumVersion) =>
      'arm64-apple-ios$minimumVersion-simulator';
  @override
  String minimumVersionFlag(String minimumVersion) =>
      '-mios-simulator-version-min=$minimumVersion';
}
