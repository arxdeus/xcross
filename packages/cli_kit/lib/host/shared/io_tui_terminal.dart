import 'dart:io';

import 'package:cli_kit/shared/tui/tui.dart';

final class IoTuiTerminal implements TuiTerminal {
  IoTuiTerminal({required this.input, required this.output});
  final Stdin input;
  final IOSink output;
  late bool _echoMode;
  late bool _lineMode;
  bool _raw = false;

  @override
  bool get isInteractive => input.hasTerminal;

  @override
  void enterRaw() {
    if (_raw) return;
    _echoMode = input.echoMode;
    _lineMode = input.lineMode;
    input
      ..echoMode = false
      ..lineMode = false;
    _raw = true;
  }

  @override
  void leaveRaw() {
    if (!_raw) return;
    input
      ..echoMode = _echoMode
      ..lineMode = _lineMode;
    _raw = false;
  }

  @override
  int readByte() => input.readByteSync();

  @override
  String? readLine() => input.readLineSync();

  @override
  void write(String value) => output.write(value);
}
