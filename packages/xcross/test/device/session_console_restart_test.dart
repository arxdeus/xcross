import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:test/test.dart';
import 'package:xcross/src/constants.dart';
import 'package:xcross/src/device/session_console.dart';

void main() {
  // Kotlin/Native Compose has no in-place reload, so its session supplies a
  // rebuild-and-relaunch handler. `r` and `R` must both route there instead
  // of reaching the Flutter hot reload/restart code, which would either warn
  // "hot reload is not available" or drive a frontend_server that Compose
  // does not have.
  SessionConsole consoleWith(List<String> events) => SessionConsole(
    gdb: GdbRemoteClient(host: '127.0.0.1', port: 0),
    hotReload: null,
    onRestartRequested: () async {
      events.add('restart');
      return false;
    },
  );

  test("'r' asks the owner to rebuild and relaunch", () async {
    final events = <String>[];
    await consoleWith(events).handleKeyByte([DeviceConstants.keyR]);
    expect(events, ['restart']);
  });

  test("'R' uses the same rebuild path as 'r'", () async {
    final events = <String>[];
    await consoleWith(events).handleKeyByte([DeviceConstants.keyBigR]);
    expect(events, ['restart']);
  });

  test('a refused restart leaves the session running', () async {
    final events = <String>[];
    final console = consoleWith(events);

    await console.handleKeyByte([DeviceConstants.keyR]);
    await console.handleKeyByte([DeviceConstants.keyR]);

    // Both presses are served: refusing a restart (no source changes, or a
    // failed build) must not wedge the console.
    expect(events, ['restart', 'restart']);
  });

  test('without a restart handler r does not crash the session', () async {
    final console = SessionConsole(
      gdb: GdbRemoteClient(host: '127.0.0.1', port: 0),
      hotReload: null,
      hotReloadUnavailable: 'no reload here',
    );

    await expectLater(console.handleKeyByte([DeviceConstants.keyR]), completes);
  });
}
