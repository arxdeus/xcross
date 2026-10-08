import 'dart:io';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';

@internal
final class SdkDirectoryCopy<T extends PlatformHostInterface> {
  const SdkDirectoryCopy(this.host);
  final T host;
  Future<void> copy(String source, String destination) async {
    await host.fileSystem.directory(destination).create(recursive: true);
    await for (final entity in host.fileSystem.directory(source).list()) {
      final name = host.paths.context.basename(entity.path);
      final target = host.paths.context.join(destination, name);
      if (entity is Directory) {
        await copy(host.paths.context.join(source, name), target);
      } else if (entity is File) {
        await entity.copy(host.fileSystem.file(target).path);
      }
    }
  }
}
