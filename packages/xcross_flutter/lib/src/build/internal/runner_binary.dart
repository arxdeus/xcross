import 'package:meta/meta.dart';

/// Result of building the ObjC Runner shim: the xcframework used and the
/// linked Runner binary path.
@immutable
final class RunnerBinary {
  const RunnerBinary({required this.xcframework, required this.runnerBinary});

  final String xcframework;
  final String runnerBinary;
}
