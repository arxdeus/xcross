import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/errors.dart';

/// Copies Flutter's generated compressed license notices into App.framework.
@internal
final class FlutterNoticeArtifact {
  const FlutterNoticeArtifact({required this.fileSystem, required this.paths});
  final HostFileSystemInterface fileSystem;
  final p.Context paths;
  void copy({
    required String sourceFlutterAssetsDirectory,
    required String destinationFlutterAssetsDirectory,
  }) {
    final source = fileSystem.file(
      paths.join(sourceFlutterAssetsDirectory, 'NOTICES.Z'),
    );
    if (!source.existsSync()) {
      throw FlutterBuildError(
        'Flutter iOS asset assembly did not produce $source',
      );
    }

    final destination = fileSystem.file(
      paths.join(destinationFlutterAssetsDirectory, 'NOTICES.Z'),
    );
    source.copySync(destination.path);
  }
}
