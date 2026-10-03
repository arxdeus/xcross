import 'dart:io';

import 'package:dart_mobile_device/src/shared/console/device_console.dart';

final class NativeDeviceConsole implements DeviceConsole {
  const NativeDeviceConsole({required this.input, required this.output});
  @override
  Stream<void> get interrupts => ProcessSignal.sigint.watch().map((_) {});
  final Stdin input;
  final Stdout output;
  @override
  bool get inputHasTerminal => input.hasTerminal;
  @override
  bool get outputHasTerminal => output.hasTerminal;
  @override
  bool get echoMode => input.echoMode;
  @override
  set echoMode(bool value) => input.echoMode = value;
  @override
  bool get lineMode => input.lineMode;
  @override
  set lineMode(bool value) => input.lineMode = value;
  @override
  String? readLine() => input.readLineSync();
  @override
  void write(String value) => output.write(value);
  @override
  void writeln(String value) => output.writeln(value);
  @override
  void add(List<int> value) => output.add(value);
}
