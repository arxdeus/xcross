import 'package:test/test.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';
import 'package:xcross/src/target/iphone/device/core_device_launcher.dart';
import 'package:xcross/src/target/iphone/device/device_log.dart';

import 'test_log_output.dart';

void main() {
  test('VM connection failures preserve Error and Exception identity', () {
    final error = StateError('socket failed');
    final exception = Exception('connection refused');
    for (final failure in [error, exception]) {
      expect(
        () => CoreDeviceLauncher.throwVmServiceConnectionFailure(failure),
        throwsA(same(failure)),
      );
    }
  });

  test('arbitrary VM failure retains useful connection context', () {
    expect(
      () => CoreDeviceLauncher.throwVmServiceConnectionFailure('bad channel'),
      throwsA(
        isA<XcrossError>().having(
          (error) => error.toString(),
          'message',
          contains('VM Service connection failed: bad channel'),
        ),
      ),
    );
    expect(
      () => CoreDeviceLauncher.throwVmServiceConnectionFailure(null),
      throwsA(
        isA<XcrossError>().having(
          (error) => error.toString(),
          'message',
          contains('VM Service did not become available'),
        ),
      ),
    );
  });

  test('background launch failure tells the user to unlock the device', () {
    expect(
      CoreDeviceLauncher.launchFailureMessage(
        'DTXNsError: Background launch requested, but this app cannot run '
        'in the background',
      ),
      'Launch failed: iOS rejected a background launch. Unlock the iPhone, '
      'keep its screen awake, and run again.',
    );
  });

  test('other launch failures retain their original cause', () {
    expect(
      CoreDeviceLauncher.launchFailureMessage('connection lost'),
      'Launch failed: connection lost',
    );
  });

  test('r/R explain the missing reload by build mode', () {
    expect(
      CoreDeviceLauncher.reloadUnavailableReason(FlutterBuildMode.profile),
      startsWith('hot reload is not supported in profile mode'),
    );
    expect(
      CoreDeviceLauncher.reloadUnavailableReason(FlutterBuildMode.release),
      startsWith('hot reload is not supported in release mode'),
    );
    expect(
      CoreDeviceLauncher.reloadUnavailableReason(null),
      startsWith('this session has no in-place reload'),
    );
  });

  test('device logs use unbuffered UTF-8 Python output', () {
    expect(DeviceLog.processEnvironment(const {'EXISTING': 'value'}), {
      'EXISTING': 'value',
      'PYTHONUNBUFFERED': '1',
      'PYTHONIOENCODING': 'utf-8',
    });
  });

  test('device logs keep only the launched process', () {
    expect(
      DeviceLog.appLogMessage(
        '{"pid":13457,"message":"first Flutter frame rendered"}',
        13457,
      ),
      'first Flutter frame rendered',
    );
    expect(
      DeviceLog.appLogMessage(
        '{"pid":42,"message":"unrelated system log"}',
        13457,
      ),
      isNull,
    );
    expect(DeviceLog.appLogMessage('not json', 13457), isNull);
  });

  test('device logs select the device over plain usbmux', () {
    // Never the session transport's `--userspace --udid` args: a second
    // in-process tunnel to an already-tunnelled device stalls and yields no
    // lines, which is how a crash reason went missing entirely.
    expect(DeviceLog.deviceSelectionArgs('00008030-ABC'), [
      '--udid',
      '00008030-ABC',
    ]);
    expect(DeviceLog.deviceSelectionArgs(null), isEmpty);
  });

  String pick(List<String> installed, String requested) =>
      CoreDeviceLauncher.pickInstalledBundleId(
        log: testLog(),
        installed: installed,
        requested: requested,
      );

  test('prefers the XCR-qualified build over the production one', () {
    expect(
      pick([
        'com.production.app',
        'XCR-ABCD1234.com.production.app',
      ], 'com.production.app'),
      'XCR-ABCD1234.com.production.app',
    );
  });

  test('falls back to the requested id when no qualified build exists', () {
    expect(
      pick(['com.production.app'], 'com.production.app'),
      'com.production.app',
    );
  });

  test('does not match unrelated suffixes', () {
    expect(
      pick(['com.other.com.example.App'], 'com.example.App'),
      'com.example.App',
    );
  });

  test('shortest qualified match wins', () {
    expect(
      pick([
        'XCR-LONGERTEAMID.com.example.App',
        'XCR-ABCD.com.example.App',
      ], 'com.example.App'),
      'XCR-ABCD.com.example.App',
    );
  });

  test('does not match an extension of the app id', () {
    expect(
      pick(['XCR-ABCD.com.example.App.Share-Extension'], 'com.example.App'),
      'com.example.App',
    );
  });

  test('already-qualified request resolves to itself', () {
    expect(
      pick(['XCR-ABCD.com.example.App'], 'XCR-ABCD.com.example.App'),
      'XCR-ABCD.com.example.App',
    );
  });
}
