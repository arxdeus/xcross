import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/sdk/sdk_install_constants.dart';

@internal
final class SdkJsonFileWriter<T extends PlatformHostInterface> {
  const SdkJsonFileWriter(this.host);
  final T host;
  Future<void> write(String path, Map<String, Object?> value) => host.fileSystem
      .file(path)
      .writeAsString('${sdkJsonEncoder.convert(value)}\n');
}
