import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/shared/flutter/ios_gen_snapshot_host.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/ios_gen_snapshot_mode.dart';

@internal
final class LinuxIosGenSnapshotHost implements IosGenSnapshotHost {
  const LinuxIosGenSnapshotHost(this.host);

  @override
  final LinuxHostInterface host;

  @override
  String get prebuiltPlatform {
    if (!const ['arm64', 'x64'].contains(host.architecture)) {
      throw FlutterBuildError(
        'No iOS AOT compiler is published for Linux ${host.architecture} '
        'hosts; only x64 and arm64 are supported.',
      );
    }
    return 'linux-${host.architecture}';
  }

  @override
  String? flutterCompiler(String engineDirectory, IosGenSnapshotMode mode) =>
      null;
}
