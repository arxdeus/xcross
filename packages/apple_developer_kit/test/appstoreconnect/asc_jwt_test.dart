import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:test/test.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_config.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_jwt.dart';

void main() {
  group('AscJwt.generate', () {
    late Directory tmp;
    late AscCredentials credentials;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('xcross_asc_jwt-');
      // A throwaway EC keypair stands in for a real Apple .p8 key - no real
      // API key needed to test the JWT's structure/encoding.
      final keyPair = CryptoUtils.generateEcKeyPair();
      final pem = CryptoUtils.encodeEcPrivateKeyToPem(
        keyPair.privateKey as ECPrivateKey,
      );
      final keyFile = File('${tmp.path}/AuthKey_TESTKEY123.p8');
      await keyFile.writeAsString(pem);
      credentials = AscCredentials(
        issuerId: 'issuer-1234',
        keyId: 'TESTKEY123',
        privateKeyPath: keyFile.path,
      );
    });

    tearDown(() => tmp.delete(recursive: true));

    test(
      'produces a 3-part base64url JWT with the right header/payload',
      () async {
        final token = await AscJwt.generate(credentials);
        final parts = token.split('.');
        expect(parts, hasLength(3));

        for (final part in parts) {
          // Unpadded, per JWS's base64url requirement (RFC 7515 §2).
          expect(part, isNot(contains('=')));
        }

        Map<String, dynamic> decodePart(String part) =>
            jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(part))))
                as Map<String, dynamic>;

        final header = decodePart(parts[0]);
        expect(header['alg'], 'ES256');
        expect(header['kid'], 'TESTKEY123');
        expect(header['typ'], 'JWT');

        final payload = decodePart(parts[1]);
        expect(payload['iss'], 'issuer-1234');
        expect(payload['aud'], 'appstoreconnect-v1');
        expect(payload['iat'], isA<int>());
        expect(payload['exp'], greaterThan(payload['iat'] as int));

        // JWS ES256 wants the raw r||s concatenation: 32 bytes each for P-256.
        final signatureBytes = base64Url.decode(base64Url.normalize(parts[2]));
        expect(signatureBytes, hasLength(64));
      },
    );
  });
}
