import 'package:cli_kit/cli_kit_shared.dart';

Log sdkTestLog() => Log(output: SdkTestLogOutput());

final class SdkTestLogOutput implements LogOutput {
  final List<String> messages = [];
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
