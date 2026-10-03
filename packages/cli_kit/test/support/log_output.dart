import 'package:cli_kit/src/logging.dart';

final class RecordingLogOutput implements LogOutput {
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
