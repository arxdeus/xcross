import 'package:meta/meta.dart';

@internal
enum ComposeConfiguration { debug, release }

@internal
final class ComposeBuildOptions {
  const ComposeBuildOptions({
    this.configuration = ComposeConfiguration.debug,
    this.bundleId,
    this.appName,
    this.ipa = false,
  });
  final ComposeConfiguration configuration;
  final String? bundleId;
  final String? appName;
  final bool ipa;
}
