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
    this.frameworkOnly = false,
  });
  final ComposeConfiguration configuration;
  final String? bundleId;
  final String? appName;
  final bool ipa;

  /// Build only the Kotlin/Native framework, even when the project has a
  /// Swift app or a Kotlin entry point.
  ///
  /// A host app that xcross does not assemble (a SwiftPM package built with
  /// xtool, an Xcode project on macOS) links the framework itself and needs
  /// nothing else from the build.
  final bool frameworkOnly;
}
