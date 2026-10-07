import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/composition/native_host.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/test_log_output.dart';

void main() {
  test(
    'capture and echo writes only to the explicitly supplied IO sinks',
    () async {
      final host = detectPlatformHost();
      final temporary = Directory.systemTemp.createTempSync(
        'runner-explicit-io-',
      );
      addTearDown(() => temporary.deleteSync(recursive: true));
      final script = File(p.join(temporary.path, 'output.dart'))
        ..writeAsStringSync(
          'import "dart:io"; void main() { stdout.write("out-é"); stderr.write("error"); }',
        );
      final output = StreamController<List<int>>();
      final error = StreamController<List<int>>();
      addTearDown(output.close);
      addTearDown(error.close);
      final outputBytes = <int>[];
      final errorBytes = <int>[];
      output.stream.listen(outputBytes.addAll);
      error.stream.listen(errorBytes.addAll);
      final outputSink = IOSink(output.sink);
      final errorSink = IOSink(error.sink);
      addTearDown(() async {
        await outputSink.close();
        await errorSink.close();
      });
      final input = StreamController<List<int>>();
      addTearDown(input.close);
      final runner = ProcessRunner(
        host,
        log: Log(output: TestLogOutput(emit: print)),
        stdinStream: input.stream,
        stdoutSink: outputSink,
        stderrSink: errorSink,
      );
      await runner.runChecked(Platform.resolvedExecutable, [
        script.path,
      ], captureAndEcho: true);
      await outputSink.flush();
      await errorSink.flush();
      expect(utf8.decode(outputBytes), 'out-é');
      expect(utf8.decode(errorBytes), 'error');
      final received = <List<int>>[];
      final subscription = runner.sharedStdin.listen(received.add);
      input.add([1, 2, 3]);
      await Future<void>.delayed(Duration.zero);
      expect(received, [
        [1, 2, 3],
      ]);
      await input.close();
      await subscription.cancel();
    },
  );
}
