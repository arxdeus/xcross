import 'package:cli_kit/src/logging.dart';

class RecordingLogOutput implements LogOutput {
  RecordingLogOutput({this.supportsAnsi = false, this.terminalColumns = 80});
  @override
  final bool supportsAnsi;
  @override
  final int terminalColumns;
  final List<String> lines = [];
  final List<String> errors = [];
  final List<String> writes = [];
  @override
  void stdout(String message) => lines.add(message);
  @override
  void stderr(String message) => errors.add(message);
  @override
  void write(String message) => writes.add(message);
}

final class ThrowingLogOutput extends RecordingLogOutput {
  ThrowingLogOutput({super.supportsAnsi, this.failWriteAt, this.failStdoutAt});
  final int? failWriteAt;
  final int? failStdoutAt;
  int writeAttempts = 0;
  int stdoutAttempts = 0;
  final error = StateError('output failed');
  @override
  void write(String message) {
    writeAttempts++;
    if (failWriteAt != null && writeAttempts >= failWriteAt!) throw error;
    super.write(message);
  }

  @override
  void stdout(String message) {
    stdoutAttempts++;
    if (failStdoutAt != null && stdoutAttempts >= failStdoutAt!) throw error;
    super.stdout(message);
  }
}
