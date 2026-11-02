import 'package:meta/meta.dart';

/// Result of building the ObjC Runner shim: the xcframework used and the
/// linked Runner binary path.
@internal
@immutable
final class RunnerBinary {
  const RunnerBinary({
    required this.xcframework,
    required this.runnerBinary,
    required this.sdkName,
    this.sdkPath,
  });

  final String xcframework;
  final String runnerBinary;
  final String sdkName;

  /// The platform SDK the Runner was linked against, whose
  /// `SystemVersion.plist` (and the Xcode `version.plist` beside it) supply
  /// the `DT*` provenance keys Xcode stamps into Info.plist.
  final String? sdkPath;
}
