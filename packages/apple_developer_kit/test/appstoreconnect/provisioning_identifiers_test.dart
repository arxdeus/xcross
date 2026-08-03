import 'package:apple_developer_kit/src/appstoreconnect/provisioning_identifiers.dart';
import 'package:test/test.dart';

void main() {
  test('qualifies with first identity segment uppercased', () {
    expect(
      ProvisioningIdentifiers.qualify(
        'com.example.Hello',
        'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
      ),
      'XCR-A1B2C3D4.com.example.Hello',
    );
    expect(
      ProvisioningIdentifiers.qualify('com.example.Hello', '64E91B3F9A'),
      'XCR-64E91B3F9A.com.example.Hello',
    );
  });

  test('sanitize strips a leading XCR- segment', () {
    expect(
      ProvisioningIdentifiers.sanitize('XCR-ABCD.com.example.Hello'),
      'com.example.Hello',
    );
    expect(
      ProvisioningIdentifiers.sanitize('com.example.Hello'),
      'com.example.Hello',
    );
  });

  test('qualify is idempotent after sanitize', () {
    const identity = 'TEAMID1234';
    final once = ProvisioningIdentifiers.qualify('com.example.App', identity);
    final twice = ProvisioningIdentifiers.qualify(once, identity);
    expect(twice, once);
  });

  test('appName uses sanitized id', () {
    expect(
      ProvisioningIdentifiers.appName('XCR-ABCD.com.example.my-app'),
      'xcross com example my app',
    );
  });
}
