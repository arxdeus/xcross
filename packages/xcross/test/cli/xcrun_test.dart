import 'dart:io';

import 'package:test/test.dart';

import '../../bin/xcrun.dart' as xcrun;

void main() {
  test('rejects an invocation without a tool', () async {
    expect(await xcrun.runXcrun(const []), 1);
  });

  test('returns the exact streamed child exit code', () async {
    final child = await Process.start('sh', const ['-c', 'exit 37']);
    expect(
      await xcrun.runResolvedTool(
        '/ignored',
        const [],
        start: (_, _) async => child,
      ),
      37,
    );
  });
}
