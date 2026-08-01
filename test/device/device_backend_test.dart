import 'package:test/test.dart';
import 'package:xcross/src/device/device_backend.dart';

void main() {
  test(
    'Windows always chooses the native backend even when xtool is found',
    () async {
      final backend = await DeviceBackend.resolve(
        windows: true,
        which: (_) async => r'C:\tools\xtool.exe',
      );

      expect(backend, isA<NativeBackend>());
    },
  );

  test('non-Windows keeps the existing xtool preference', () async {
    final backend = await DeviceBackend.resolve(
      windows: false,
      which: (_) async => '/usr/bin/xtool',
    );

    expect(backend, isA<XtoolBackend>());
  });
}
