import 'dart:convert';

import 'package:test/test.dart';
import 'package:xcross/src/appstoreconnect/appstoreconnect.dart';

void main() {
  group('wrapDerAsPem', () {
    test('wraps base64 DER content into a line-wrapped PEM block', () {
      final der = base64.encode(List<int>.generate(200, (i) => i % 256));
      final pem = wrapDerAsPem(der);

      expect(pem, startsWith('-----BEGIN CERTIFICATE-----\n'));
      expect(pem, endsWith('-----END CERTIFICATE-----\n'));

      final lines = pem.trim().split('\n');
      final bodyLines = lines.sublist(1, lines.length - 1);
      for (final line in bodyLines.sublist(0, bodyLines.length - 1)) {
        expect(line.length, 64);
      }

      // Round-trips back to the original DER bytes.
      expect(base64.decode(bodyLines.join()), base64.decode(der));
    });

    test('supports a custom label', () {
      final pem = wrapDerAsPem(
        base64.encode([1, 2, 3]),
        label: 'RSA PRIVATE KEY',
      );
      expect(pem, startsWith('-----BEGIN RSA PRIVATE KEY-----\n'));
      expect(pem, contains('-----END RSA PRIVATE KEY-----'));
    });
  });
}
