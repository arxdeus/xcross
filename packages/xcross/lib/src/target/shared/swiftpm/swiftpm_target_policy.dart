import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';

/// The per-target decisions the SwiftPM engine needs to cross-compile and
/// assemble Swift packages for one iOS destination.
@internal
abstract interface class SwiftPmTargetPolicy<T extends PlatformHostInterface> {
  IosTarget<T> get target;

  /// XCFramework library identifiers usable for this target, in preference
  /// order (for example `ios-arm64` or `ios-arm64_x86_64-simulator`).
  List<String> get xcframeworkSliceIdentifiers;

  /// Whether an XCFramework library with `SupportedPlatformVariant`
  /// [variant] serves this target.
  bool matchesLibraryVariant(String? variant);

  /// Suffix of the per-project workspace directory under the SwiftPM cache.
  String get workspaceSuffix;

  /// Directory name of the shared binary-artifact store under the cache.
  String get binaryArtifactDirectory;
}
