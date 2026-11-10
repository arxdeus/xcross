import 'dart:io';
import 'package:meta/meta.dart';

@internal
typedef StartBinaryCopy =
    Future<BinaryCopyProcess> Function(
      String executable,
      List<String> arguments,
    );

@internal
abstract interface class BinaryCopyProcess {
  Future<int> get exitCode;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  bool kill();
}

@internal
final class RunnerBinaryCopyProcess implements BinaryCopyProcess {
  const RunnerBinaryCopyProcess(this.process);
  final Process process;
  @override
  Future<int> get exitCode => process.exitCode;
  @override
  Stream<List<int>> get stdout => process.stdout;
  @override
  Stream<List<int>> get stderr => process.stderr;
  @override
  bool kill() => process.kill();
}

@internal
abstract interface class SwiftPmArtifactCopyPolicy {
  Future<void> copy({
    required String source,
    required Directory destination,
    required Duration timeout,
  });
}

@internal
final class SwiftPmLiveCopyException extends FileSystemException {
  const SwiftPmLiveCopyException(super.message, super.path);
}
