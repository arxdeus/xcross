import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/composition/flutter/posix_flutter_feature_services.dart';
import 'package:xcross/src/host/linux/flutter/swiftpm/host_build_services.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_build_services.dart';

final class LinuxFlutterFeatureServices<T extends LinuxHostInterface>
    extends PosixFlutterFeatureServices<T> {
  const LinuxFlutterFeatureServices({
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
      LinuxSwiftPmHostBuildServices<T>(
        target: target,
        filesystem: checkoutManifestNormalizer.filesystem,
        sdkIdentity: sdkIdentity,
      );
}
