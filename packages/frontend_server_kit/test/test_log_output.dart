import 'package:cli_kit/cli_kit.dart';

Log testLog() => Log(output: TestLogOutput());

final class TestLogOutput implements LogOutput {
  final messages = <String>[];
  @override
  bool get supportsAnsi => false;
  @override
  int get terminalColumns => 80;
  @override
  void stdout(String message) => messages.add(message);
  @override
  void stderr(String message) => messages.add(message);
  @override
  void write(String message) => messages.add(message);
}
