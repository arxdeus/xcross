import 'dart:async';

import 'package:test/test.dart';
import 'package:xcross/src/update/update_progress.dart';

Future<List<String>> _captureAsync(Future<void> Function() body) async {
  final lines = <String>[];
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, __, ___, line) => lines.add(line),
    ),
  );
  return lines;
}

void main() {
  test('declares release and source phases in order', () {
    expect(UpdatePhases.release, const [
      'Download release archive',
      'Download checksum manifest',
      'Verify archive',
      'Extract release bundle',
      'Install release',
      'Verify installed release',
    ]);
    expect(UpdatePhases.source, const [
      'Clone repository',
      'Fetch commit',
      'Check out commit',
      'Resolve dependencies',
      'Build xcross',
      'Install source build',
      'Verify installed source build',
    ]);
  });

  test('numbers phases in order', () {
    final progress = UpdateProgress('Source', 3);

    expect(
      progress.nextLabel('Clone repository'),
      'Source [1/3] Clone repository',
    );
    expect(progress.nextLabel('Fetch commit'), 'Source [2/3] Fetch commit');
    expect(progress.nextLabel('Build xcross'), 'Source [3/3] Build xcross');
    expect(() => progress.nextLabel('extra'), throwsStateError);
  });

  test('run reports one start and one completion line', () async {
    final lines = await _captureAsync(() async {
      final progress = UpdateProgress('Release', 1);
      await progress.run('Verify archive', () async {});
    });

    expect(
      lines.where((line) => line.contains('Release [1/1] Verify archive')),
      hasLength(2),
    );
    expect(
      lines.where((line) => line.contains('Release [1/1] Verify archive…')),
      hasLength(1),
    );
    expect(
      lines.where(
        (line) =>
            line.contains('Release [1/1] Verify archive') &&
            !line.contains('…'),
      ),
      hasLength(1),
    );
  });
}
