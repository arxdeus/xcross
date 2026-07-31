/// A pure-Dart port of xtool's `SRPClient` (SRP-6a client for Apple's
/// GrandSlam / GSA login protocol), used to authenticate an Apple ID with
/// an email + password without going through Xcode/Swift.
///
/// This file is a faithful, line-by-line port of xtool's
/// `Sources/XKit/GrandSlam/Crypto/SRPClient.swift` (fetched directly from
/// https://github.com/xtool-org/xtool at port time). Method-level doc
/// comments below reference the corresponding Swift method so a reviewer
/// can diff this against the original.
///
/// This module implements ONLY the SRP-6a crypto primitives (key exchange
/// math, password->x derivation, proof construction, and the small
/// AES-CBC decryption helper for the `spd` field). It does not perform any
/// networking or GrandSlam/plist protocol orchestration - that is a
/// separate, later layer that will drive this class.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart' as pc;

/// RFC 5054 §A 2048-bit SRP group prime `N`, exactly as used by xtool.
/// This is the well-known, public RFC 5054 constant - not a project secret.
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

/// Byte length of `N`'s big-endian representation (2048 bits = 256 bytes).
/// xtool hard-codes this same value in two places (`calcXY`'s padding
/// width, and `g`'s padding width via `SHA256.byteCount * 8 == 256`) which
/// only coincide because this implementation is fixed to the 2048-bit
/// group; we use one named constant for both.
final int _nByteLength = (_n.bitLength + 7) ~/ 8;

/// The result of [SrpClient.processChallenge]: the client's `M` proof to
/// send to the server, plus the client's public key `A` (handed back for
/// convenience even though the caller already has it via [SrpClient.publicKey]).
class SrpChallengeResult {
  SrpChallengeResult({required this.clientProof});

  /// `M`, called `M1` in Apple's client-facing docs: sent to the server so
  /// it can verify the client derived the same session key.
  final Uint8List clientProof;
}

/// SRP-6a client for Apple's GrandSlam authentication, matching xtool's
/// `SRPClient` (RFC 5054 2048-bit group, SHA-256, Apple's custom `x`
/// derivation and proof/negotiated-protocol framing).
///
/// Typical usage (the actual network exchange is a later layer):
/// ```dart
/// final client = SrpClient();
/// final a = client.publicKey; // send to server as `A`
/// // ... receive salt / iterations / protocol / B from server ...
/// final m1 = client.processChallenge(
///   username: appleId,
///   password: password,
///   salt: salt,
///   iterations: iterations,
///   isLegacyProtocol: protocol == 's2k_fo',
///   serverPublicKey: b,
/// );
/// // ... send m1 to server, receive hamk (M2) back ...
/// if (!client.verifyServerProof(hamk)) throw Exception('bad server proof');
/// final plaintext = client.decryptCbc(spdCiphertext);
/// ```
class SrpClient {
  /// Generates the client's ephemeral private/public keypair (`a`/`A`).
  ///
  /// Matches Swift `init()`: `a` is 256 secure-random bits (deliberately
  /// smaller than `N`; this is what xtool does - 256 bits of entropy is
  /// more than enough security margin regardless of `N`'s size), and
  /// `A = g^a mod N`.
  SrpClient() : _a = _randomBigInt(256) {
    _bigA = _g.modPow(_a, _n);
  }

  final BigInt _a;
  late final BigInt _bigA;

  // Populated by [processChallenge]; used by [verifyServerProof],
  // [decryptCbc], [addString]/[addData]/[verifyNegotiatedProtocols].
  Uint8List? _sessionKeyBytes; // K
  Uint8List? _expectedHamk;

  // Running digest accumulator, matches Swift's `var digest = SHA256()`
  // plus incremental `add(string:)`/`add(data:)`. xtool feeds this with
  // GrandSlam protocol-negotiation data (e.g. the comma-joined list of
  // offered `s2k`/`s2k_fo` protocols) both before and after the SRP
  // challenge is processed; the exact sequence is decided by the caller
  // (the not-yet-built GrandSlam orchestration layer), so this class only
  // exposes the primitives, same as xtool's `SRPClient` does.
  final BytesBuilder _digestBuffer = BytesBuilder();

  /// Client's public SRP value `A`, to send to the server.
  ///
  /// Matches Swift `func publicKey() -> Data { clientPublicKey.serialize() }`.
  Uint8List get publicKey => _bigIntToBytes(_bigA);

  /// Shared session secret `S`, only available after [processChallenge].
  /// Exposed mainly for testing (see the self-consistency test in
  /// `test/grandslam/`); GrandSlam itself only uses [sessionKey] (`K`).
  BigInt? sharedSecret;

  /// `K = SHA256(S)`, the session key later layers use to derive
  /// per-purpose HMAC keys. Only available after [processChallenge].
  Uint8List? get sessionKey => _sessionKeyBytes;

  /// Feeds a UTF-8 string into the running negotiated-protocol digest.
  ///
  /// Matches Swift `mutating func add(string: String)`.
  void addString(String value) {
    _digestBuffer.add(_utf8(value));
  }

  /// Feeds length-prefixed bytes into the running negotiated-protocol
  /// digest.
  ///
  /// Matches Swift `mutating func add(data: Data)`, which prefixes the
  /// data with its length as a native-endian `UInt32` before hashing.
  /// Swift's "native endian" is little-endian on every platform xtool
  /// actually ships for (Apple's arm64/x86_64); we hard-code little-endian
  /// to match real-world behavior. This is a single-source (xtool-only)
  /// detail, unverified against real GrandSlam traffic - see the
  /// class-level doc comment.
  void addData(Uint8List data) {
    final lengthPrefix = ByteData(4)..setUint32(0, data.length, Endian.little);
    _digestBuffer.add(lengthPrefix.buffer.asUint8List());
    _digestBuffer.add(data);
  }

  /// Processes the server's SRP challenge and returns the client's proof
  /// (`M`) to send back to the server.
  ///
  /// Matches Swift `mutating func processChallenge(withUsername:password:
  /// salt:iterations:isLegacyProtocol:serverPublicKey:) throws -> Data`.
  ///
  /// - [username]: the Apple ID (only used in the `M` proof hash, per
  ///   xtool's source - NOT mixed into the `x`/password-verifier derivation).
  /// - [isLegacyProtocol]: `true` for the `s2k_fo` protocol variant
  ///   (hex-re-encodes the password hash before PBKDF2), `false` for the
  ///   modern default `s2k` variant.
  /// - [serverPublicKey]: the server's raw `B` bytes, exactly as received
  ///   on the wire (used verbatim in the `M` hash, not re-serialized from
  ///   the parsed BigInt - matches xtool using `rawB` there).
  ///
  /// Throws [ArgumentError] if `B mod N == 0` (the standard SRP safeguard
  /// against a malicious/degenerate server public key).
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

    // --- x = SRP password verifier exponent (Apple's custom s2k/s2k_fo) ---
    final hashedPassword = Uint8List.fromList(
      crypto.sha256.convert(_utf8(password)).bytes,
    );
    final Uint8List pbkdfInput;
    if (isLegacyProtocol) {
      pbkdfInput = _utf8(_lowercaseHex(hashedPassword));
    } else {
      pbkdfInput = hashedPassword;
    }
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

    // --- standard SRP-6a math ---
    final u = _calcXY(_bigA, bigB);
    final k = _calcXY(_n, _g);

    final v = _g.modPow(x, _n); // password verifier
    // Dart's BigInt `%` is Euclidean (always non-negative for a positive
    // divisor), so this already matches Swift's explicit
    // `.modulus(BigInt(N))` step after the signed subtraction.
    final base = (bigB - (v * k) % _n) % _n;
    final s = base.modPow(_a + u * x, _n);
    sharedSecret = s;

    final sessionKeyBytes = Uint8List.fromList(
      crypto.sha256.convert(_bigIntToBytes(s)).bytes,
    );
    _sessionKeyBytes = sessionKeyBytes;

    // --- M / hamk proof (RFC 5054-shaped: H(N) xor H(g), H(I), s, A, B, K) ---
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

  /// Verifies the server's `hamk` (`M2`) proof against the one this client
  /// computed during [processChallenge].
  ///
  /// Matches Swift `func verify(hamk: Data) -> Bool`.
  bool verifyServerProof(Uint8List hamk) {
    final expected = _expectedHamk;
    if (expected == null) return false;
    return _constantTimeEquals(expected, hamk);
  }

  /// Verifies a server-provided HMAC (`negProto`) of the running
  /// negotiated-protocol digest built via [addString]/[addData].
  ///
  /// Matches Swift `func verify(negProto: Data) -> Bool`. Single-source
  /// (xtool-only) and structurally novel - see the class-level doc
  /// comment; not independently verifiable without real GrandSlam traffic.
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

  /// Decrypts an AES-256-CBC/PKCS7 blob (e.g. the GrandSlam response's
  /// `spd` field) using keys derived from the SRP session key.
  ///
  /// Matches Swift `func decrypt(cbc: Data) throws -> Data`, which derives
  /// the AES key/IV as `HMAC-SHA256(clientKey, "extra data key:"/"extra
  /// data iv:")` (IV truncated to the first 16 bytes), where `clientKey`
  /// is `K` itself (not a further re-derivation).
  ///
  /// PKCS7 padding is assumed for the underlying `AES._CBC` Swift Crypto
  /// API (its `encrypt`/`decrypt` convenience methods pad/unpad
  /// automatically); this is a reasonable, standard assumption but is
  /// unverified against real Apple response bytes - flagged per the task
  /// spec as something to double-check once real GrandSlam traffic is
  /// available.
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

  /// `HMAC-SHA256(key: K, message: utf8(name))`, matching Swift's private
  /// `sessionKey(name:)` helper (used for both the CBC key/IV derivation
  /// and the `negProto` HMAC key).
  Uint8List _sessionSubkey(Uint8List sessionKeyBytes, String name) =>
      _hmacSha256(key: sessionKeyBytes, message: _utf8(name));

  /// `SHA256(pad(x, N-byte-length) || pad(y, N-byte-length))`, interpreted
  /// as an unsigned big-endian integer. Matches Swift's private `calcXY`,
  /// used for both `u = calcXY(A, B)` and `k = calcXY(N, g)`.
  BigInt _calcXY(BigInt x, BigInt y) {
    final padX = _padLeft(_bigIntToBytes(x), _nByteLength);
    final padY = _padLeft(_bigIntToBytes(y), _nByteLength);
    return _bytesToBigInt(crypto.sha256.convert([...padX, ...padY]).bytes);
  }
}

Uint8List _hmacSha256({required Uint8List key, required List<int> message}) =>
    Uint8List.fromList(crypto.Hmac(crypto.sha256, key).convert(message).bytes);

Uint8List _pbkdf2HmacSha256({
  required Uint8List input,
  required Uint8List salt,
  required int iterations,
  required int derivedKeyLength,
}) {
  final derivator = pc.PBKDF2KeyDerivator(pc.HMac.withDigest(pc.SHA256Digest()))
    ..init(pc.Pbkdf2Parameters(salt, iterations, derivedKeyLength));
  return derivator.process(input);
}

/// Cryptographically secure random `BigInt` with exactly [bits] bits of
/// entropy (top bit forced set so the value always has the full bit
/// length, matching interpreting `bits` secure-random bytes as an unsigned
/// big-endian integer).
BigInt _randomBigInt(int bits) {
  final random = Random.secure();
  final byteLength = (bits + 7) ~/ 8;
  final bytes = Uint8List.fromList(
    List<int>.generate(byteLength, (_) => random.nextInt(256)),
  );
  return _bytesToBigInt(bytes);
}

/// Minimal unsigned big-endian byte representation of a non-negative
/// [BigInt] (matches Swift `BigUInt.serialize()` - no sign byte, no
/// padding). `0` serializes as a single zero byte; this never arises for
/// real SRP values (public keys are checked non-zero, secrets are random).
Uint8List _bigIntToBytes(BigInt value) {
  assert(!value.isNegative, 'SRP big-integer values must be non-negative');
  var hex = value.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

BigInt _bytesToBigInt(List<int> bytes) {
  var result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b);
  }
  return result;
}

Uint8List _padLeft(Uint8List bytes, int length) {
  if (bytes.length >= length) return bytes;
  final padded = Uint8List(length);
  padded.setRange(length - bytes.length, length, bytes);
  return padded;
}

Uint8List _utf8(String value) => Uint8List.fromList(utf8.encode(value));

String _lowercaseHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
