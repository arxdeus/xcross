import 'package:cli_kit/shared/logging/logging.dart';
import 'package:meta/meta.dart';

@internal
final class TestLogOutput implements LogOutput {
  TestLogOutput({required this.emit});
  final void Function(String) emit;
  @override
  bool get supportsAnsi => false;
  @override
  int get terminalColumns => 80;
  @override
  void stdout(String message) => emit(message);
  @override
  void stderr(String message) => emit(message);
  @override
  void write(String message) => emit(message);
}
