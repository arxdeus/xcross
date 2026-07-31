// Tests for [SrpClient].
//
// Two kinds of coverage, per the task spec (there is no official published
// test-vector set for Apple's exact SRP flavor):
//
//  1. Known-value sanity checks for the underlying primitives (SHA-256,
//     HMAC-SHA-256, PBKDF2-HMAC-SHA-256) against independently-published
//     IETF test vectors (RFC 4231, RFC 7914 section 11) - confirms this
//     file calls the crypto libraries correctly (parameter order, output
//     length), not a re-test of the libraries themselves.
//  2. A self-consistency test: a minimal, independently-written SRP-6a
//     "server" simulation (below) registers a synthetic password and runs
//     the full exchange against the real [SrpClient], asserting the
//     client's and server's independently-derived `S`/`K` match. This is
//     the primary correctness proof for the SRP-6a math and the Apple
//     `x` derivation, since there's no official Apple test-vector set to
//     check against directly.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart' as pc;
import 'package:test/test.dart';
import 'package:xcross/src/grandslam/srp_client.dart';

String _bytesToHex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('primitive sanity checks (known IETF test vectors)', () {
    test('SHA-256("abc") matches the well-known NIST/FIPS 180 value', () {
      final digest = crypto.sha256.convert(utf8.encode('abc'));
      expect(
        _bytesToHex(digest.bytes),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('HMAC-SHA-256 matches RFC 4231 Test Case 2', () {
      final key = utf8.encode('Jefe');
      final data = utf8.encode('what do ya want for nothing?');
      final mac = crypto.Hmac(crypto.sha256, key).convert(data);
      expect(
        _bytesToHex(mac.bytes),
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
      );
    });

    test('PBKDF2-HMAC-SHA-256 matches RFC 7914 section 11, vector 1', () {
      final derivator = pc.PBKDF2KeyDerivator(pc.HMac.withDigest(pc.SHA256Digest()))
        ..init(pc.Pbkdf2Parameters(utf8.encode('salt'), 1, 64));
      final derived = derivator.process(utf8.encode('passwd'));
      expect(
        _bytesToHex(derived),
        '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc'
        '49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783',
      );
    });

    test('PBKDF2-HMAC-SHA-256 matches RFC 7914 section 11, vector 2 (c=80000)', () {
      final derivator = pc.PBKDF2KeyDerivator(pc.HMac.withDigest(pc.SHA256Digest()))
        ..init(pc.Pbkdf2Parameters(utf8.encode('NaCl'), 80000, 64));
      final derived = derivator.process(utf8.encode('Password'));
      expect(
        _bytesToHex(derived),
        '4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56'
        'a1d425a12258 33549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d'
            .replaceAll(' ', ''),
      );
    });
  });

  group('SrpClient self-consistency (independent server-side simulation)', () {
    for (final legacy in [false, true]) {
      test(
        'client/server derive matching S and K (${legacy ? 's2k_fo' : 's2k'} protocol)',
        () {
          const username = 'test@example.com';
          const password = 'correct horse battery staple';
          final salt = _randomBytes(16);
          const iterations = 1000; // low, only for test speed

          final client = SrpClient();
          final bigA = _bytesToBigInt(client.publicKey);

          // --- independent "server" registration + challenge ---
          final x = _computeXIndependently(
            password: password,
            salt: salt,
            iterations: iterations,
            legacy: legacy,
          );
          final v = _g.modPow(x, _n); // password verifier, stored at "registration"
          final b = _randomBigInt(256);
          final k = _calcXYIndependently(_n, _g);
          final bigB = (k * v + _g.modPow(b, _n)) % _n;

          final m1 = client.processChallenge(
            username: username,
            password: password,
            salt: salt,
            iterations: iterations,
            isLegacyProtocol: legacy,
            serverPublicKey: _bigIntToBytes(bigB),
          );

          // --- independent server-side session secret ---
          final u = _calcXYIndependently(bigA, bigB);
          final sServer = (bigA * v.modPow(u, _n) % _n).modPow(b, _n);
          final kServer = crypto.sha256.convert(_bigIntToBytes(sServer)).bytes;

          expect(client.sharedSecret, sServer, reason: 'S must match on both sides');
          expect(client.sessionKey, kServer, reason: 'K = SHA256(S) must match on both sides');

          // Server's hamk (M2), computed independently, must verify.
          final aBytes = client.publicKey;
          final hamkServer = crypto.sha256.convert([...aBytes, ...m1, ...kServer]).bytes;
          expect(client.verifyServerProof(Uint8List.fromList(hamkServer)), isTrue);

          // A tampered hamk must be rejected.
          final tampered = Uint8List.fromList(hamkServer);
          tampered[0] ^= 0xff;
          expect(client.verifyServerProof(tampered), isFalse);
        },
      );
    }

    test('rejects a degenerate server public key (B ≡ 0 mod N)', () {
      final client = SrpClient();
      expect(
        () => client.processChallenge(
          username: 'a@b.com',
          password: 'pw',
          salt: _randomBytes(16),
          iterations: 1000,
          isLegacyProtocol: false,
          serverPublicKey: _bigIntToBytes(_n * BigInt.two), // multiple of N
        ),
        throwsArgumentError,
      );
    });

    test('two clients derive independent, unequal ephemeral key pairs', () {
      final a = SrpClient();
      final b = SrpClient();
      expect(a.publicKey, isNot(equals(b.publicKey)));
    });
  });
}

// ---------------------------------------------------------------------
// Independent, test-only SRP-6a "server" math below. Deliberately
// implemented with different low-level plumbing (bit-shift big-integer
// <-> bytes conversion rather than production's hex-string approach) so
// this isn't just re-running the same code under test.
// ---------------------------------------------------------------------

final BigInt _n = BigInt.parse(
  'AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC31929'
  '43DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310D'
  'CD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FB'
  'D5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF74'
  '7359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A'
  '436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D'
  '5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E73'
  '03CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6'
  '94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F'
  '9E4AFF73',
  radix: 16,
);
final BigInt _g = BigInt.two;
final int _nByteLength = (_n.bitLength + 7) ~/ 8;

BigInt _computeXIndependently({
  required String password,
  required Uint8List salt,
  required int iterations,
  required bool legacy,
}) {
  final hashedPassword = Uint8List.fromList(crypto.sha256.convert(utf8.encode(password)).bytes);
  final Uint8List pbkdfInput;
  if (legacy) {
    pbkdfInput = Uint8List.fromList(utf8.encode(_bytesToHex(hashedPassword)));
  } else {
    pbkdfInput = hashedPassword;
  }
  final derivator = pc.PBKDF2KeyDerivator(pc.HMac.withDigest(pc.SHA256Digest()))
    ..init(pc.Pbkdf2Parameters(salt, iterations, 32));
  final passkey = derivator.process(pbkdfInput);
  final inner = crypto.sha256.convert([0x3a, ...passkey]).bytes; // ":" + passkey
  final x = crypto.sha256.convert([...salt, ...inner]).bytes;
  return _bytesToBigInt(x);
}

BigInt _calcXYIndependently(BigInt x, BigInt y) {
  final padX = _padLeft(_bigIntToBytes(x), _nByteLength);
  final padY = _padLeft(_bigIntToBytes(y), _nByteLength);
  return _bytesToBigInt(crypto.sha256.convert([...padX, ...padY]).bytes);
}

Uint8List _padLeft(Uint8List bytes, int length) {
  if (bytes.length >= length) return bytes;
  final padded = Uint8List(length);
  padded.setRange(length - bytes.length, length, bytes);
  return padded;
}

/// Bit-shift-based big-endian encoder (deliberately not the hex-string
/// approach used in `lib/src/grandslam/srp_client.dart`).
Uint8List _bigIntToBytes(BigInt value) {
  if (value == BigInt.zero) return Uint8List.fromList([0]);
  final bytes = <int>[];
  var n = value;
  final mask = BigInt.from(0xff);
  while (n > BigInt.zero) {
    bytes.insert(0, (n & mask).toInt());
    n = n >> 8;
  }
  return Uint8List.fromList(bytes);
}

BigInt _bytesToBigInt(List<int> bytes) {
  var result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) + BigInt.from(b);
  }
  return result;
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(List<int>.generate(length, (_) => random.nextInt(256)));
}

BigInt _randomBigInt(int bits) => _bytesToBigInt(_randomBytes((bits + 7) ~/ 8));
