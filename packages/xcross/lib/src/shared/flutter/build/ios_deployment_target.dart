import 'package:darwin_sdk_kit/target/shared/ios_build_platform.dart';
import 'package:meta/meta.dart';

@internal
final class IosDeploymentTarget {
  const IosDeploymentTarget(this.version, {required this.platform});

  static const fallbackVersion = '13.0';

  final String version;
  final IosBuildPlatformInterface platform;

  IosBuildPlatformInterface get target => platform;

  String get buildTriple => target.buildTriple(version);

  String get swiftSdkTriple => target.swiftSdkTriple;

  String get linkerPlatform => target.linkerPlatform;

  String get minimumVersionFlag => platform.minimumVersionFlag(version);
}
