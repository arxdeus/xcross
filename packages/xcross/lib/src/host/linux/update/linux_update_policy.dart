import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/shared/update/posix_update_policy.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/update/install_layout.dart';
import 'package:xcross/src/shared/update/update_host_policy.dart';

@internal
final class LinuxUpdatePolicy implements UpdateHostPolicy {
  const LinuxUpdatePolicy(this.host, this.runner, this.privileges);
  final LinuxHostInterface host;
  final ProcessRunner runner;
  final HostPrivilegesInterface privileges;
  @override
  String releaseAsset() => switch (host.architecture) {
    'x64' => 'xcross-linux-x64.tar.gz',
    'arm64' => 'xcross-linux-arm64.tar.gz',
    _ => throw XcrossError(
      'no prebuilt xcross release for linux/${host.architecture}; build from source instead',
    ),
  };
  @override
  Future<FileSwapOperations> prepare(InstallLayout layout) =>
      preparePosixUpdate(host, runner, privileges, layout);
}
