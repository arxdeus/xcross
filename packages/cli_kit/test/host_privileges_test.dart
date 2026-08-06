import 'package:cli_kit/src/errors.dart';
import 'package:cli_kit/src/host_privileges.dart';
import 'package:cli_kit/src/process.dart';
import 'package:test/test.dart';

void main() {
  test('accepts an elevated Windows process', () async {
    await HostPrivileges.ensureDeviceToolAccess(
      windows: true,
      windowsProbe: () async => const CapturedProcess(0, 'True\r\n', ''),
    );
  });

  test('gives an actionable error for a non-admin Windows process', () async {
    await expectLater(
      HostPrivileges.ensureDeviceToolAccess(
        windows: true,
        windowsProbe: () async => const CapturedProcess(0, 'False\r\n', ''),
      ),
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
