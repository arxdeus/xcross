import 'dart:async';

import 'package:test/test.dart';
import 'package:xcross/src/util/process.dart';

void main() {
  // Regression: `xtool install` forwards stdin to the child, then cancels.
  // With a plain `stdin.listen`, that cancel closes the fd for good and
  // SessionConsole's later listen fires onDone at once — the session quit the
  // instant the app launched and r/R did nothing.
  test('a second listener still receives events after the first cancels',
      () async {
    final source = StreamController<int>();
    final shared = ProcessRunner.pausingBroadcast(source.stream);

    final first = shared.listen((_) {});
    await first.cancel();

    var done = false;
    final seen = <int>[];
    shared.listen(seen.add, onDone: () => done = true);

    source.add(1);
    source.add(2);
    await Future<void>.delayed(Duration.zero);

    expect(seen, [1, 2]);
    expect(done, isFalse, reason: 'source must not have been torn down');
    await source.close();
  });

  test('events sent between listeners are not lost', () async {
    final source = StreamController<int>();
    final shared = ProcessRunner.pausingBroadcast(source.stream);

    await shared.listen((_) {}).cancel();
    source.add(7); // nobody listening — must queue, not vanish

    final seen = <int>[];
    shared.listen(seen.add);
    await Future<void>.delayed(Duration.zero);

    expect(seen, [7]);
    await source.close();
  });
}
