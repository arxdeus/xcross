import 'dart:io';
import 'package:cli_kit/cli_kit_shared.dart';

final class SdkDirectoryCopy<T extends PlatformHostInterface> {
  const SdkDirectoryCopy(this.host);
  final T host;
  Future<void> copy(String source, String destination) async {
    await Directory(host.paths.ioPath(destination)).create(recursive: true);
    await for (final entity in Directory(host.paths.ioPath(source)).list()) {
      final target = host.paths.context.join(
        destination,
        host.paths.context.basename(entity.path),
      );
      switch (FileSystemEntity.typeSync(entity.path)) {
        case FileSystemEntityType.directory:
          await copy(entity.path, target);
        case FileSystemEntityType.file:
          await File(entity.path).copy(host.paths.ioPath(target));
        default:
          continue;
      }
    }
  }
}
