import 'package:darwin_sdk_kit/src/target/shared/ios_build_platform.dart';

final class IPhoneBuildPlatform implements IosBuildPlatformInterface {
  const IPhoneBuildPlatform();
  @override
  String get sdkName => 'iphoneos';
  @override
  String get platformName => 'iPhoneOS';
  @override
  String get swiftSdkTriple => 'arm64-apple-ios';
  @override
  String get linkerPlatform => 'ios';
  @override
  String buildTriple(String minimumVersion) => 'arm64-apple-ios$minimumVersion';
  @override
  String minimumVersionFlag(String minimumVersion) =>
      '-miphoneos-version-min=$minimumVersion';
}
