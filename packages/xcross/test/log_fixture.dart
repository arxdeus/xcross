import 'dart:async';
import 'dart:io';

import 'package:cli_kit/shared/logging/logging.dart';
import 'package:meta/meta.dart';

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
Log testLog() => Log(output: TestLogOutput());

@internal
final class TestByteConsumer implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach((_) {});
  @override
  Future<void> close() async {}
}

@internal
IOSink testByteSink() => IOSink(TestByteConsumer());
