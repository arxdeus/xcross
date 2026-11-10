import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/composition/swiftpm/posix_swiftpm_services.dart';
import 'package:xcross/src/host/linux/swiftpm/host_build_services.dart';
import 'package:xcross/src/shared/swiftpm/host_build_services.dart';

@internal
final class LinuxSwiftPmServices<T extends LinuxHostInterface>
    extends PosixSwiftPmServices<T> {
  const LinuxSwiftPmServices({
    required super.checkout,
    required super.checkoutAttributes,
    required super.checkoutManifestNormalizer,
    required super.runner,
    required super.repository,
    required super.toolchain,
    required super.hostTools,
    required super.hostPolicy,
    required super.artifactFileSystem,
    required super.sdkIdentity,
    required super.resolution,
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
