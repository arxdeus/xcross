import 'package:meta/meta.dart';

@internal
enum ComposeConfiguration { debug, release }

/// Which app entry point to build when a project declares more than one.
@internal
enum ComposeEntryPreference {
  /// The SwiftUI `@main` host in `iosApp/` when there is one, otherwise the
  /// Kotlin `ComposeUIViewController` entry, otherwise the framework only.
  auto,

  /// The SwiftUI `@main` host. Fails when the project has none.
  swift,

  /// The Kotlin `ComposeUIViewController` entry, launched by a generated
  /// runner. Fails when the project has none.
  kotlin,
}

@internal
final class ComposeBuildOptions {
  const ComposeBuildOptions({
    this.configuration = ComposeConfiguration.debug,
    this.bundleId,
    this.appName,
    this.ipa = false,
    this.frameworkOnly = false,
    this.entry = ComposeEntryPreference.auto,
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

  /// The entry point the app is built from.
  final ComposeEntryPreference entry;
}
