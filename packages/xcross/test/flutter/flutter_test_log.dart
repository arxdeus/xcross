import 'package:cli_kit/cli_kit_shared.dart';

final class RecordingFlutterLogOutput implements LogOutput {
  final messages = <String>[];
  final errors = <String>[];
  @override
  bool get supportsAnsi => false;
  @override
  int get terminalColumns => 80;
  @override
  void stdout(String message) => messages.add(message);
  @override
  void stderr(String message) => errors.add(message);
  @override
  void write(String message) => messages.add(message);
}

Log testFlutterLog({bool verbose = false}) =>
    Log(output: RecordingFlutterLogOutput(), verbose: verbose);
