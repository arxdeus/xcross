import 'package:meta/meta.dart';

/// Build configuration for `xcross compose`.
enum ComposeConfiguration {
  debug,
  release;

  /// Lower-case name passed as the `CONFIGURATION` env var and for logging.
  String get label => name; // 'debug' or 'release'
}

/// Options shared by `xcross compose build` and `run`.
@immutable
class ComposeOptions {
  const ComposeOptions({
    this.configuration = ComposeConfiguration.release,
    this.sign = false,
    this.ipa = false,
  });

  /// Build configuration — defaults to release for `build`, debug for `run`.
  final ComposeConfiguration configuration;

  /// Whether to codesign after packing (delegates to `xtool install`).
  final bool sign;

  /// Whether to produce an `.ipa` instead of a bare `.app`.
  final bool ipa;
}
