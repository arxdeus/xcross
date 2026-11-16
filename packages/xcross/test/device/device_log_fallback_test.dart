import 'package:test/test.dart';
import 'package:xcross/src/target/iphone/device/device_log.dart';

import 'test_log_output.dart';

/// Issue #167: when hot reload cannot start, the session falls back to the
/// device log for the app's Dart output instead of going silent.
void main() {
  DeviceLog logWith(List<String> printed) =>
      DeviceLog.forTesting(logger: testLog())
        ..setOutputForTesting(printed.add)
        ..rememberForTesting('flutter: before setup failed')
        ..rememberForTesting('nw_resolver_start_query chatter')
        ..rememberForTesting('flutter: second line');

  test('replays Dart output the never-connected VM Service dropped', () {
    final printed = <String>[];
    logWith(printed).echoDartOutputFromNowOn(replay: true);
    expect(printed, ['before setup failed', 'second line']);
  });

  test('does not replay output the VM Service already forwarded', () {
    final printed = <String>[];
    logWith(printed).echoDartOutputFromNowOn(replay: false);
    expect(printed, isEmpty);
  });

  test('switching on twice never prints a line twice', () {
    final printed = <String>[];
    logWith(printed)
      ..echoDartOutputFromNowOn(replay: true)
      ..echoDartOutputFromNowOn(replay: true);
    expect(printed, ['before setup failed', 'second line']);
  });
}
