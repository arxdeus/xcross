import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/target/shared/swiftpm/swiftpm_target_policy.dart';

/// SwiftPM policy for physical iPhone builds.
@internal
final class IPhoneSwiftPmTarget<T extends PlatformHostInterface>
    implements SwiftPmTargetPolicy<T> {
  const IPhoneSwiftPmTarget(this.target);
  @override
  final IPhoneTargetInterface<T> target;
  @override
  List<String> get xcframeworkSliceIdentifiers => const ['ios-arm64'];
  @override
  bool matchesLibraryVariant(String? variant) => variant == null;
  @override
  String get workspaceSuffix => '';
  @override
  String get binaryArtifactDirectory => 'binary-artifacts-v1';
}
