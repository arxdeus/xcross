import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_host_build_services.dart';

@internal
final class LinuxSwiftPmHostBuildServices<T extends PlatformHostInterface>
    extends PosixSwiftPmHostBuildServices<T> {
  LinuxSwiftPmHostBuildServices({
    required super.target,
    required super.filesystem,
    required super.sdkIdentity,
  });
  @override
  Future<void> rewriteDylib(String path, Set<String> names) => Future.value();
}
