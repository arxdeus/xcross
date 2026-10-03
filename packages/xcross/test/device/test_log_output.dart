import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart' show DeviceConsole;

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

final class TestDeviceConsole implements DeviceConsole {
  @override
  Stream<void> get interrupts => const Stream.empty();
  @override
  bool get inputHasTerminal => false;
  @override
  bool get outputHasTerminal => false;
  @override
  bool echoMode = true;
  @override
  bool lineMode = true;
  @override
  String? readLine() => null;
  @override
  void write(String value) {}
  @override
  void writeln(String value) {}
  @override
  void add(List<int> bytes) {}
}

LocalHttp<PlatformHostInterface> testLocalHttp() =>
    LocalHttp(MacOSHost(), createClient: HttpClient.new);

IOSink testSink() => IOSink(StreamController<List<int>>.broadcast().sink);
