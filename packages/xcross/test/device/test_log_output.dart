import 'dart:async';
import 'dart:io';

import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/shared/http/local_http.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:dart_mobile_device/shared/console/device_console.dart';
import 'package:meta/meta.dart';

@internal
Log testLog() => Log(output: TestLogOutput());

@internal
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

@internal
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

@internal
LocalHttp<PlatformHostInterface> testLocalHttp() =>
    LocalHttp(MacOSHost(), createClient: HttpClient.new);

@internal
IOSink testSink() => IOSink(StreamController<List<int>>.broadcast().sink);
