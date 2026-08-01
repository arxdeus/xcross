import 'dart:io';

import 'package:test/test.dart';
import 'package:xcross/src/device/device_backend.dart';

void main() {
  test('always resolves the native backend', () async {
    expect(await DeviceBackend.resolve(), isA<NativeBackend>());
  });

  test('locates zsign before provisioning mutates the server', () {
    final source = File(
      'lib/src/device/device_backend.dart',
    ).readAsStringSync();
    final locate = source.indexOf('await ZsignCli.locate();');
    final provision = source.indexOf(
      'await provisionDevelopmentIdentity(',
      locate,
    );

    expect(locate, greaterThanOrEqualTo(0));
    expect(provision, greaterThan(locate));
  });
}
