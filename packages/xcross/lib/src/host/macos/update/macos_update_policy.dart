import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/host/shared/update/posix_update_policy.dart';
import 'package:xcross/src/shared/update/update_host_policy.dart';
import 'package:xcross/src/update/install_layout.dart';

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
