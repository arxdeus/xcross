import 'package:meta/meta.dart';

@internal
abstract interface class CommandPrompt {
  bool get isInteractive;
  void write(String value);
  String? readLine(String prompt);
  String? readSecret(String prompt, {required String valueName});
}
