import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/sdk/sdk_archive_links.dart';

@internal
final class PreservedSdkArchiveLinks<T extends PlatformHostInterface>
    implements SdkArchiveLinksInterface {
  const PreservedSdkArchiveLinks(this.host);
  final T host;
  @override
  Future<void> createLinks(
    Map<String, String> links, {
    void Function(int done, int total)? onProgress,
  }) async {
    var linked = 0;
    for (final link in links.entries) {
      await host.fileSystem
          .link(link.key)
          .create(
            host.paths.context.relative(
              link.value,
              from: host.paths.context.dirname(link.key),
            ),
            recursive: true,
          );
      onProgress?.call(++linked, links.length);
    }
  }
}
