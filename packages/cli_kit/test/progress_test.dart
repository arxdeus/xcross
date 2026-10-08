import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/progress/progress.dart';
import 'package:test/test.dart';

import 'support/log_output.dart';

void main() {
  test('plain progress reports deciles and finishes exactly once', () {
    final output = RecordingLogOutput();
    final log = Log(output: output);
    final progress = ProgressBar(
      'Extract',
      log: log,
      total: 100,
      unit: ProgressUnit.items,
    );
    progress.update(1);
    progress.update(2);
    progress.update(15);
    progress.note = 'files';
    progress.update(100);
    progress.finish();
    progress.finish();
    progress.fail();
    expect(output.lines, hasLength(4));
    expect(output.lines.first, contains('1%'));
    expect(output.lines[2], contains('100%'));
    expect(output.lines.last, contains('100'));
  });

  test('progress interrupts only the owning session step', () {
    final log = Log(output: RecordingLogOutput());
    final other = Log(output: RecordingLogOutput());
    final first = log.beginStep('First');
    final second = other.beginStep('Second');
    final progress = ProgressBar('Transfer', log: log);
    expect(log.activeStep, isNull);
    expect(other.activeStep, same(second));
    progress.finish();
    first.done();
    second.done();
  });

  test('terminal rendering uses injected width and clears on failure', () {
    final output = RecordingLogOutput(supportsAnsi: true);
    final progress = ProgressBar(
      'Transfer',
      log: Log(output: output),
      total: 100,
    );
    progress.update(25);
    expect(output.writes.single, contains('25%'));
    progress.fail('failed');
    expect(output.writes.last, '\r\x1B[K');
    expect(output.lines.single, contains('✗'));
    final count = output.writes.length;
    progress.update(80);
    progress.note = 'late';
    expect(output.writes, hasLength(count));
  });

  test('unknown totals suppress plain updates until final report', () {
    final output = RecordingLogOutput();
    final progress = ProgressBar('Transfer', log: Log(output: output));
    progress.add(1536);
    expect(output.lines, isEmpty);
    progress.finish();
    expect(output.lines.single, contains('1.5 KB'));
  });

  test('formatters remain pure', () {
    expect(ProgressBar.formatBytes(1023), '1023 B');
    expect(ProgressBar.formatBytes(1536), '1.5 KB');
    expect(ProgressBar.formatBytes(1024 * 1024), '1.0 MB');
    expect(ProgressBar.formatCount(12431), '12,431');
  });
}
