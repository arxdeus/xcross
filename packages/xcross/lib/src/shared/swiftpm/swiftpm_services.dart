import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/swiftpm/package_builder.dart';
import 'package:xcross/src/target/shared/swiftpm/swiftpm_target_policy.dart';

/// How Apple tool shims locate xcross and its bundled tools.
@internal
final class AppleToolResolution {
  const AppleToolResolution({
    required this.executable,
    this.launcher,
    this.xcrun,
    this.openAppleMacrosServer,
    this.declarative = false,
  });
  final String executable;
  final String? launcher;
  final String? xcrun;
  final String? openAppleMacrosServer;
  final bool declarative;
}

/// The host's SwiftPM services, ready to build Swift packages for any iOS
/// target. Flutter and Compose both obtain their [SwiftPmPackageBuilder]
/// here.
@internal
abstract interface class SwiftPmServices<T extends PlatformHostInterface> {
  ProcessRunner<T> get runner;

  /// A builder whose engine is configured for [policy]. Each call wires a
  /// fresh engine; callers keep the builder for the lifetime of a build.
  SwiftPmPackageBuilder<T> builder(SwiftPmTargetPolicy<T> policy);
}
