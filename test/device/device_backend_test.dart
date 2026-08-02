import 'dart:io';

import 'package:test/test.dart';
import 'package:xcross/src/device/device_backend.dart';

void main() {
  test('always resolves the native backend', () async {
    expect(await DeviceBackend.resolve(), isA<NativeBackend>());
  });

  test('rejects non-app inputs before provisioning mutates Apple state', () {
    final source = File(
      'lib/src/device/device_backend.dart',
    ).readAsStringSync();
    final guard = source.indexOf(
      'in-process signer currently supports xcross-generated .app',
    );
    final provision = source.indexOf('await provisionDevelopmentIdentity(');

    expect(guard, greaterThanOrEqualTo(0));
    expect(provision, greaterThan(guard));
    expect(source, isNot(contains('ZsignCli')));
  });
}
