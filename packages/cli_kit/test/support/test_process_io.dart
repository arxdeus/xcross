import 'dart:async';
import 'dart:io';
import 'package:meta/meta.dart';

@internal
final class TestProcessIo {
  TestProcessIo() {
    _output.stream.listen((_) {});
    _error.stream.listen((_) {});
    output = IOSink(_output.sink);
    error = IOSink(_error.sink);
  }

  final Stream<List<int>> input = const Stream<List<int>>.empty();
  final StreamController<List<int>> _output = StreamController<List<int>>();
  final StreamController<List<int>> _error = StreamController<List<int>>();
  late final IOSink output;
  late final IOSink error;

  Future<void> close() async {
    await Future.wait([output.close(), error.close()]);
    await Future.wait([_output.close(), _error.close()]);
  }
}
