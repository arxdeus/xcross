import 'dart:convert';

import 'package:test/test.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/update/checksums.dart';

const _payload = 'xcross';

/// A well-formed digest, used where only the line shape is under test.
const _payloadDigest =
    'b1bc19a3c0a8f0d4d0f47dd0dc0a1a08db2bc0dc5b8e8dbf9c0d2c1e2f1ee4a4';

/// The real digest of [_payload], for the verification tests.
String _realDigest() => Checksums.digestOf(utf8.encode(_payload));

void main() {
  group('parse', () {
    test('reads the two-space form sha256sum writes', () {
      final digests = Checksums.parse(
        '$_payloadDigest  xcross-linux-x64.tar.gz\n'
        '$_payloadDigest  xcross-windows-x64.zip\n',
      );
      expect(digests, hasLength(2));
      expect(digests['xcross-linux-x64.tar.gz'], _payloadDigest);
    });

    test('keys every published release archive separately', () {
      const assets = [
        'xcross-linux-x64.tar.gz',
        'xcross-linux-arm64.tar.gz',
        'xcross-windows-x64.zip',
        'xcross-windows-arm64.zip',
      ];
      String digestFor(int index) =>
          _payloadDigest.substring(0, 63) + index.toRadixString(16);
      final digests = Checksums.parse(
        [
          for (final (index, asset) in assets.indexed)
            '${digestFor(index)}  $asset\n',
        ].join(),
      );
      expect(digests, {
        for (final (index, asset) in assets.indexed) asset: digestFor(index),
      });
    });

    test('accepts the binary-mode star and lowercases the digest', () {
      final digests = Checksums.parse(
        '${_payloadDigest.toUpperCase()} *xcross-linux-arm64.tar.gz\n',
      );
      expect(digests['xcross-linux-arm64.tar.gz'], _payloadDigest);
    });

    test('skips blank lines', () {
      expect(
        Checksums.parse('\n  \n$_payloadDigest  a.tar.gz\n\n'),
        hasLength(1),
      );
    });

    // Two entries for one name would let a manifest carry both the genuine
    // digest and one matching a substituted archive.
    test('rejects a duplicate entry for the same file', () {
      expect(
        () => Checksums.parse(
          '$_payloadDigest  asset.tar.gz\n'
          '${_payloadDigest.replaceFirst('b', 'c')}  asset.tar.gz\n',
        ),
        throwsA(
          isA<XcrossError>().having(
            (e) => e.message,
            'message',
            contains('more than once'),
          ),
        ),
      );
    });

    test('rejects malformed input instead of silently dropping it', () {
      for (final bad in [
        'not a checksum line',
        'deadbeef  short-digest.tar.gz',
        _payloadDigest,
        '<html><body>404</body></html>',
      ]) {
        expect(
          () => Checksums.parse(bad),
          throwsA(isA<XcrossError>()),
          reason: 'expected "$bad" to be rejected',
        );
      }
    });
  });

  group('verify', () {
    test('passes when the digest matches', () {
      Checksums.verify(
        name: 'asset.tar.gz',
        bytes: utf8.encode(_payload),
        contents: '${_realDigest()}  asset.tar.gz\n',
      );
    });

    test('fails closed when the asset has no entry', () {
      expect(
        () => Checksums.verify(
          name: 'asset.tar.gz',
          bytes: utf8.encode(_payload),
          contents: '${_realDigest()}  other.tar.gz\n',
        ),
        throwsA(
          isA<XcrossError>().having(
            (e) => e.message,
            'message',
            contains('no entry for asset.tar.gz'),
          ),
        ),
      );
    });

    test('fails on a mismatch', () {
      expect(
        () => Checksums.verify(
          name: 'asset.tar.gz',
          bytes: utf8.encode('tampered'),
          contents: '${_realDigest()}  asset.tar.gz\n',
        ),
        throwsA(
          isA<XcrossError>().having(
            (e) => e.message,
            'message',
            contains('checksum mismatch'),
          ),
        ),
      );
    });
  });
}
