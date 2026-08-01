import 'package:test/test.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/host_privileges.dart';
import 'package:xcross/src/util/process.dart';

void main() {
  test('accepts an elevated Windows process', () async {
    await HostPrivileges.ensureDeviceToolAccess(
      windows: true,
      windowsProbe: () async => CapturedProcess(0, 'True\r\n', ''),
    );
  });

  test('gives an actionable error for a non-admin Windows process', () async {
    await expectLater(
      HostPrivileges.ensureDeviceToolAccess(
        windows: true,
        windowsProbe: () async => CapturedProcess(0, 'False\r\n', ''),
      ),
      throwsA(
        isA<XcrossError>().having(
          (error) => error.toString(),
          'message',
          contains('Run as administrator'),
        ),
      ),
    );
  });
}
