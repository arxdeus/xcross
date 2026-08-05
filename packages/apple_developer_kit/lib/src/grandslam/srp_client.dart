/// SRP-6a client for Apple's GrandSlam / GSA login, a pure-Dart port of
/// xtool's `Sources/XKit/GrandSlam/Crypto/SRPClient.swift`.
///
/// Crypto primitives only: the key-exchange math, Apple's `s2k`/`s2k_fo`
/// password->`x` derivation, the proof construction, and the AES-CBC
/// helper that opens the `spd` field. Networking and plist orchestration
/// live in `grandslam_login.dart`.
///
/// WARNING: every hash input, its ordering, and every byte-padding width
/// below is protocol-critical. A one-byte change silently breaks login.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';
import 'package:pointycastle/export.dart' as pc;

/// RFC 5054 §A 2048-bit SRP group prime `N`. A well-known public
/// constant, not a project secret.
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

/// `g = 2`, the RFC 5054 2048-bit group generator.
final BigInt _g = BigInt.two;

/// Padding width for every hashed group element: `N`'s big-endian length
/// (256 bytes). xtool hard-codes this twice - once in `calcXY`, once for
/// `g` via `SHA256.byteCount * 8` - which only coincide because this
/// implementation is fixed to the 2048-bit group.
final int _nByteLength = (_n.bitLength + 7) ~/ 8;

/// SRP-6a client for Apple's GrandSlam authentication: RFC 5054 2048-bit
/// group and SHA-256, with Apple's own `x` derivation and
/// proof/negotiated-protocol framing.
///
/// ```dart
/// final client = SrpClient();
/// // send client.publicKey as `A`; receive salt/iterations/protocol/B
/// final m1 = client.processChallenge(
///   username: appleId,
///   password: password,
///   salt: salt,
///   iterations: iterations,
///   isLegacyProtocol: protocol == 's2k_fo',
///   serverPublicKey: b,
/// );
/// // send m1, receive hamk (M2)
/// if (!client.verifyServerProof(hamk)) throw Exception('bad server proof');
/// final plaintext = client.decryptCbc(spdCiphertext);
/// ```
@internal
class SrpClient {
  /// Generates the ephemeral keypair: `a` is 256 secure-random bits
  /// (deliberately smaller than `N`, as xtool does - 256 bits of entropy
  /// is ample regardless of `N`'s size) and `A = g^a mod N`.
  SrpClient() : _a = _randomBigInt(256) {
    _bigA = _g.modPow(_a, _n);
  }

  final BigInt _a;
  late final BigInt _bigA;

  Uint8List? _sessionKeyBytes; // K
  Uint8List? _expectedHamk;

  /// Running negotiated-protocol digest, fed by [addString]/[addData].
  /// The caller decides the exact sequence (see `grandslam_login.dart`),
  /// matching xtool, where `SRPClient` only exposes the primitives.
  final BytesBuilder _digestBuffer = BytesBuilder();

  /// Client public value `A`, to send to the server.
  Uint8List get publicKey => _bigIntToBytes(_bigA);

  /// Shared secret `S`, set by [processChallenge]. Exposed for the
  /// self-consistency test; GrandSlam itself only uses [sessionKey].
  BigInt? sharedSecret;

  /// `K = SHA256(S)`, set by [processChallenge]. Later layers derive
  /// per-purpose HMAC keys from it.
  Uint8List? get sessionKey => _sessionKeyBytes;

  /// Feeds a UTF-8 string into the negotiated-protocol digest.
  void addString(String value) => _digestBuffer.add(_utf8(value));

  /// Feeds length-prefixed bytes into the negotiated-protocol digest.
  ///
  /// Swift's `add(data:)` prefixes the length as a native-endian
  /// `UInt32`; native endianness is little on every platform xtool ships
  /// for, so little-endian is hard-coded here to match.
  void addData(Uint8List data) {
    final lengthPrefix = ByteData(4)..setUint32(0, data.length, Endian.little);
    _digestBuffer.add(lengthPrefix.buffer.asUint8List());
    _digestBuffer.add(data);
  }

  /// Processes the server's challenge and returns the client proof `M`
  /// (Apple's `M1`).
  ///
  /// [username] is mixed into the `M` hash only - per xtool's source it is
  /// NOT part of the `x`/password-verifier derivation. [isLegacyProtocol]
  /// selects the `s2k_fo` variant, which hex-re-encodes the password hash
  /// before PBKDF2. [serverPublicKey] is used verbatim in the `M` hash,
  /// exactly as received, not re-serialized from the parsed BigInt.
  ///
  /// Throws [ArgumentError] if `B mod N == 0`, the standard SRP safeguard
  /// against a degenerate server public key.
  @useResult
  Uint8List processChallenge({
    required String username,
    required String password,
    required Uint8List salt,
    required int iterations,
    required bool isLegacyProtocol,
    required Uint8List serverPublicKey,
  }) {
    final bigB = _bytesToBigInt(serverPublicKey);
    if (bigB % _n == BigInt.zero) {
      throw ArgumentError('server public key B is a multiple of N');
    }

    // x = SRP password verifier exponent, via Apple's s2k/s2k_fo variant.
    final hashedPassword = Uint8List.fromList(
      crypto.sha256.convert(_utf8(password)).bytes,
    );
    final pbkdfInput = isLegacyProtocol
        ? _utf8(_lowercaseHex(hashedPassword))
        : hashedPassword;
    final passkey = _pbkdf2HmacSha256(
      input: pbkdfInput,
      salt: salt,
      iterations: iterations,
      derivedKeyLength: 32,
    );
    final x = _bytesToBigInt(
      crypto.sha256.convert([
        ...salt,
        ...crypto.sha256.convert([0x3a, ...passkey]).bytes, // ":" + passkey
      ]).bytes,
    );

    // Standard SRP-6a math.
    final u = _calcXY(_bigA, bigB);
    final k = _calcXY(_n, _g);

    final v = _g.modPow(x, _n); // password verifier
    // Dart's `%` is Euclidean (never negative for a positive divisor), so
    // this already matches Swift's explicit `.modulus(BigInt(N))` after
    // the signed subtraction.
    final base = (bigB - (v * k) % _n) % _n;
    final s = base.modPow(_a + u * x, _n);
    sharedSecret = s;

    final sessionKeyBytes = Uint8List.fromList(
      crypto.sha256.convert(_bigIntToBytes(s)).bytes,
    );
    _sessionKeyBytes = sessionKeyBytes;

    // M proof, RFC 5054-shaped: H( H(N) xor H(g) | H(I) | s | A | B | K ).
    // Note H(g) is padded to `_nByteLength` but H(N) is not - that
    // asymmetry is xtool's, and is load-bearing.
    final aBytes = _bigIntToBytes(_bigA);
    final gHash = crypto.sha256
        .convert(_padLeft(_bigIntToBytes(_g), _nByteLength))
        .bytes;
    final nHash = crypto.sha256.convert(_bigIntToBytes(_n)).bytes;
    final xorHash = List<int>.generate(
      gHash.length,
      (i) => gHash[i] ^ nHash[i],
    );
    final hi = crypto.sha256.convert(_utf8(username)).bytes;
    final m = Uint8List.fromList(
      crypto.sha256.convert([
        ...xorHash,
        ...hi,
        ...salt,
        ...aBytes,
        ...serverPublicKey,
        ...sessionKeyBytes,
      ]).bytes,
    );
    _expectedHamk = Uint8List.fromList(
      crypto.sha256.convert([...aBytes, ...m, ...sessionKeyBytes]).bytes,
    );

    return m;
  }

  /// Verifies the server's `hamk` (`M2`) against the value derived during
  /// [processChallenge].
  @useResult
  bool verifyServerProof(Uint8List hamk) {
    final expected = _expectedHamk;
    if (expected == null) return false;
    return _constantTimeEquals(expected, hamk);
  }

  /// Verifies the server's `negProto` HMAC over the negotiated-protocol
  /// digest accumulated via [addString]/[addData].
  @useResult
  bool verifyNegotiatedProtocols(Uint8List negProto) {
    final key = _sessionKeyBytes;
    if (key == null) return false;
    final digestHash = crypto.sha256.convert(_digestBuffer.toBytes()).bytes;
    final mac = _hmacSha256(
      key: _sessionSubkey(key, 'HMAC key:'),
      message: digestHash,
    );
    return _constantTimeEquals(mac, negProto);
  }

  /// Decrypts an AES-256-CBC/PKCS7 blob such as the `spd` field.
  ///
  /// Key and IV are `HMAC-SHA256(K, "extra data key:"/"extra data iv:")`,
  /// the IV truncated to 16 bytes - `K` itself is the HMAC key, with no
  /// further re-derivation. PKCS7 padding matches Swift Crypto's
  /// `AES._CBC` convenience methods.
  @useResult
  Uint8List decryptCbc(Uint8List ciphertext) {
    final key = _sessionKeyBytes;
    if (key == null) {
      throw StateError('processChallenge() must be called before decryptCbc()');
    }
    final aesKey = _sessionSubkey(key, 'extra data key:');
    final iv = _sessionSubkey(key, 'extra data iv:').sublist(0, 16);

    final cipher =
        pc.PaddedBlockCipherImpl(
          pc.PKCS7Padding(),
          pc.CBCBlockCipher(pc.AESEngine()),
        )..init(
          false,
          pc.PaddedBlockCipherParameters(
            pc.ParametersWithIV(pc.KeyParameter(aesKey), iv),
            null,
          ),
        );
    return cipher.process(ciphertext);
  }

  /// `HMAC-SHA256(K, utf8(name))` - Swift's private `sessionKey(name:)`.
  Uint8List _sessionSubkey(Uint8List sessionKeyBytes, String name) =>
      _hmacSha256(key: sessionKeyBytes, message: _utf8(name));

  /// `SHA256(pad(x) || pad(y))` as an unsigned big-endian integer, where
  /// each operand is left-padded to [_nByteLength]. Used for both
  /// `u = calcXY(A, B)` and `k = calcXY(N, g)`.
  BigInt _calcXY(BigInt x, BigInt y) {
    final padX = _padLeft(_bigIntToBytes(x), _nByteLength);
    final padY = _padLeft(_bigIntToBytes(y), _nByteLength);
    return _bytesToBigInt(crypto.sha256.convert([...padX, ...padY]).bytes);
  }

  static Uint8List _hmacSha256({
    required Uint8List key,
    required List<int> message,
  }) => Uint8List.fromList(
    crypto.Hmac(crypto.sha256, key).convert(message).bytes,
  );

  static Uint8List _pbkdf2HmacSha256({
    required Uint8List input,
    required Uint8List salt,
    required int iterations,
    required int derivedKeyLength,
  }) {
    final derivator = pc.PBKDF2KeyDerivator(
      pc.HMac.withDigest(pc.SHA256Digest()),
    )..init(pc.Pbkdf2Parameters(salt, iterations, derivedKeyLength));
    return derivator.process(input);
  }

  /// Secure-random `BigInt` built from [bits] bits of entropy, read as an
  /// unsigned big-endian integer.
  static BigInt _randomBigInt(int bits) {
    final random = Random.secure();
    final byteLength = (bits + 7) ~/ 8;
    return _bytesToBigInt(
      List<int>.generate(byteLength, (_) => random.nextInt(256)),
    );
  }

  /// Minimal unsigned big-endian bytes of a non-negative [BigInt] - no
  /// sign byte and no padding, matching Swift's `BigUInt.serialize()`.
  /// `0` serializes as one zero byte, which never arises for real SRP
  /// values (public keys are checked non-zero, secrets are random).
  static Uint8List _bigIntToBytes(BigInt value) {
    assert(!value.isNegative, 'SRP big-integer values must be non-negative');
    final hex = value.toRadixString(16);
    final padded = hex.length.isOdd ? '0$hex' : hex;
    final bytes = Uint8List(padded.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(padded.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  static BigInt _bytesToBigInt(List<int> bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  static Uint8List _padLeft(Uint8List bytes, int length) {
    if (bytes.length >= length) return bytes;
    final padded = Uint8List(length);
    padded.setRange(length - bytes.length, length, bytes);
    return padded;
  }

  static Uint8List _utf8(String value) =>
      Uint8List.fromList(utf8.encode(value));

  static String _lowercaseHex(Uint8List bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
