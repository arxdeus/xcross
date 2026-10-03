import 'package:cli_kit/cli_kit.dart';
import 'package:test/test.dart';

import 'support/test_log_output.dart';
import 'support/test_process_io.dart';

void main() {
  final io = TestProcessIo();
  tearDownAll(io.close);
  final log = Log(output: TestLogOutput(emit: print));
  test('accepts an elevated Windows process', () async {
    await WindowsPrivileges(
      ProcessRunner(
        WindowsHost(),
        log: log,
        stdinStream: io.input,
        stdoutSink: io.output,
        stderrSink: io.error,
      ),
      administratorProbe: () async => const CapturedProcess(0, 'True\r\n', ''),
    ).ensureElevated();
  });

  test('gives an actionable error for a non-admin Windows process', () async {
    await expectLater(
      WindowsPrivileges(
        ProcessRunner(
          WindowsHost(),
          log: log,
          stdinStream: io.input,
          stdoutSink: io.output,
          stderrSink: io.error,
        ),
        administratorProbe: () async =>
            const CapturedProcess(0, 'False\r\n', ''),
      ).ensureElevated(),
      throwsA(
        isA<CliError>().having(
          (error) => error.toString(),
          'message',
          contains('Run as administrator'),
        ),
      ),
    );
  });
}
