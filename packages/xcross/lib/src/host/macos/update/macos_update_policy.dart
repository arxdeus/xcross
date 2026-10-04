import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/shared/update/posix_update_policy.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/update/install_layout.dart';
import 'package:xcross/src/shared/update/update_host_policy.dart';

@internal
final class MacOSUpdatePolicy implements UpdateHostPolicy {
  const MacOSUpdatePolicy(this.host, this.runner, this.privileges);
  final MacOSHostInterface host;
  final ProcessRunner runner;
  final HostPrivilegesInterface privileges;
  @override
  String releaseAsset() => throw XcrossError(
    'no prebuilt xcross release for macos/${host.architecture}; build from source instead',
  );
  @override
  Future<FileSwapOperations> prepare(InstallLayout layout) =>
      preparePosixUpdate(host, runner, privileges, layout);
}
