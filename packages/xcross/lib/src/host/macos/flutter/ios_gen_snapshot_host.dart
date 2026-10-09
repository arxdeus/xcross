import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/shared/flutter/ios_gen_snapshot_host.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/ios_gen_snapshot_mode.dart';

/// Uses the `gen_snapshot_arm64` Flutter ships with each iOS device engine,
/// from the same engine directory as the `Flutter.framework` the app embeds.
@internal
final class MacOSIosGenSnapshotHost implements IosGenSnapshotHost {
  const MacOSIosGenSnapshotHost(this.host);

  @override
  final MacOSHostInterface host;

  @override
  String get prebuiltPlatform => throw FlutterBuildError(
    'macOS hosts use the iOS AOT compiler shipped with Flutter.',
  );

  @override
  String flutterCompiler(String engineDirectory, IosGenSnapshotMode mode) {
    final compiler = host.paths.context.join(
      engineDirectory,
      'gen_snapshot_arm64',
    );
    if (!host.fileSystem.file(compiler).existsSync()) {
      throw FlutterBuildError(
        'Flutter iOS ${mode.name} compiler is missing: $compiler. Run '
        '`xcross flutter precache --mode ${mode.name}` to download it.',
      );
    }
    return compiler;
  }
}
