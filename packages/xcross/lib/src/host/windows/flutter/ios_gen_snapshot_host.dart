import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/shared/flutter/ios_gen_snapshot_host.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/ios_gen_snapshot_mode.dart';

@internal
final class WindowsIosGenSnapshotHost implements IosGenSnapshotHost {
  const WindowsIosGenSnapshotHost(this.host);

  @override
  final WindowsHostInterface host;

  @override
  String get prebuiltPlatform {
    if (!const ['arm64', 'x64'].contains(host.architecture)) {
      throw FlutterBuildError(
        'No iOS AOT compiler is published for Windows ${host.architecture} '
        'hosts; only x64 and arm64 are supported.',
      );
    }
    return 'windows-${host.architecture}';
  }

  @override
  String? flutterCompiler(String engineDirectory, IosGenSnapshotMode mode) =>
      null;
}
