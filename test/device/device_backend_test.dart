import 'package:test/test.dart';
import 'package:xcross/src/device/device_backend.dart';

void main() {
  test('always resolves the native backend', () async {
    expect(await DeviceBackend.resolve(), isA<NativeBackend>());
  });
}
