import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/composition/flutter/posix_flutter_feature_services.dart';
import 'package:xcross/src/host/macos/flutter/swiftpm/host_build_services.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_build_services.dart';

@internal
final class MacOSFlutterFeatureServices<T extends MacOSHostInterface>
    extends PosixFlutterFeatureServices<T> {
  const MacOSFlutterFeatureServices({
    required super.checkout,
    required super.checkoutAttributes,
    required super.checkoutManifestNormalizer,
    required super.runner,
    required super.repository,
    required super.toolchain,
    required super.hostTools,
    required super.renderer,
    required super.sdkPolicy,
    required super.swiftPmPolicy,
    required super.artifactFileSystem,
    required super.sdkIdentity,
    required super.resolution,
    required super.downloader,
    required super.publicationCoordinator,
    required super.transport,
    required super.copyPolicy,
  });

  @override
  SwiftPmHostBuildServices<T> hostBuildServices(IosTarget<T> target) =>
      MacOSSwiftPmHostBuildServices<T>(
        target: target,
        filesystem: checkoutManifestNormalizer.filesystem,
        sdkIdentity: sdkIdentity,
      );
}
