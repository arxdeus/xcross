import 'package:test/test.dart';
import 'package:xcross/src/device/internal/signed_bundle_identity.dart';
import 'package:xcross/src/errors.dart';

void main() {
  test('computes the exact signed id once, including qualification', () {
    final identity = SignedBundleIdentity.qualify(
      requested: 'com.example.App',
      signingIdentityId: 'team-id-with-additions',
    );

    expect(identity.requested, 'com.example.App');
    expect(identity.exact, 'XCR-TEAM.com.example.App');
  });

  test('preserves additions already present in the requested id', () {
    final identity = SignedBundleIdentity.qualify(
      requested: 'com.example.App.debug.share-host',
      signingIdentityId: 'ABC123',
    );

    expect(identity.exact, 'XCR-ABC123.com.example.App.debug.share-host');
    expect(() => identity.verifyArtifact(identity.exact), returnsNormally);
  });

  test('rejects a different artifact id before installation', () {
    final identity = SignedBundleIdentity.qualify(
      requested: 'com.example.App',
      signingIdentityId: 'ABC123',
    );

    expect(
      () => identity.verifyArtifact('XCR-OTHER.com.example.App'),
      throwsA(
        isA<XcrossError>().having(
          (error) => error.message,
          'message',
          contains('expected "XCR-ABC123.com.example.App"'),
        ),
      ),
    );
  });

  test('rejects a missing artifact id before installation', () {
    final identity = SignedBundleIdentity.qualify(
      requested: 'com.example.App',
      signingIdentityId: 'ABC123',
    );

    expect(() => identity.verifyArtifact(null), throwsA(isA<XcrossError>()));
  });
}
