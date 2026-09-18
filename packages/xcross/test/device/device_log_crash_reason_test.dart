import 'package:test/test.dart';
import 'package:xcross/src/device/device_log.dart';

void main() {
  test('keeps the app crash reason out of the surrounding noise', () {
    final log = DeviceLog.forTesting();
    log.rememberForTesting('flutter: running');
    log.rememberForTesting(
      '*** Terminating app due to uncaught exception '
      "'com.firebase.installations', reason: "
      "'[FirebaseInstallations][I-FIS008000] invalid FirebaseApp options'",
    );
    log.rememberForTesting('12.17.0 - [FirebaseAnalytics] started');

    expect(
      log.crashReason,
      contains('Terminating app due to uncaught exception'),
    );
    expect(log.recentLines, hasLength(3));
  });

  test('reports no reason when the app never explained itself', () {
    final log = DeviceLog.forTesting();
    log.rememberForTesting('flutter: running');
    expect(log.crashReason, isNull);
  });

  test('keeps only a bounded history of device output', () {
    final log = DeviceLog.forTesting();
    for (var i = 0; i < DeviceLog.recentLineLimit + 25; i++) {
      log.rememberForTesting('line $i');
    }
    expect(log.recentLines, hasLength(DeviceLog.recentLineLimit));
    expect(log.recentLines.last, 'line ${DeviceLog.recentLineLimit + 24}');
    expect(log.tailLines, hasLength(DeviceLog.printedLineLimit));
  });

  test('survives the framework chatter that follows an abort', () {
    // The reason is printed, then hundreds of networking lines arrive before
    // the debugger reports the fault. A short buffer loses it entirely.
    final log = DeviceLog.forTesting();
    log.rememberForTesting(
      '*** Terminating app due to uncaught exception, reason: bad options',
    );
    for (var i = 0; i < 100; i++) {
      log.rememberForTesting('nw_resolver noise $i');
    }
    expect(log.crashReason, contains('bad options'));
  });

  test('the newest reason wins over an older one', () {
    final log = DeviceLog.forTesting();
    log.rememberForTesting('Fatal error: first');
    log.rememberForTesting('Fatal error: second');
    expect(log.crashReason, 'Fatal error: second');
  });
}
