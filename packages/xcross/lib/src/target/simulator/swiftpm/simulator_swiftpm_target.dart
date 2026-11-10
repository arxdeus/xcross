import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/target/shared/swiftpm/swiftpm_target_policy.dart';

/// SwiftPM policy for iOS Simulator builds.
@internal
final class SimulatorSwiftPmTarget<T extends PlatformHostInterface>
    implements SwiftPmTargetPolicy<T> {
  const SimulatorSwiftPmTarget(this.target);
  @override
  final SimulatorTargetInterface<T> target;
  @override
  List<String> get xcframeworkSliceIdentifiers => const [
    'ios-arm64_x86_64-simulator',
    'ios-arm64-simulator',
  ];
  @override
  bool matchesLibraryVariant(String? variant) => variant == 'simulator';
  @override
  String get workspaceSuffix => '-simulator';
  @override
  String get binaryArtifactDirectory => 'binary-artifacts-simulator-v1';
}
