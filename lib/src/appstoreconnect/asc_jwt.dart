import 'dart:convert';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:xcross/src/appstoreconnect/asc_config.dart';

/// Builds the short-lived JWT bearer token App Store Connect API requests
/// are authenticated with (Team-scoped API key, ES256).
abstract final class AscJwt {
  static const _audience = 'appstoreconnect-v1';

  /// Token lifetime. Apple caps this at 20 minutes; 15 leaves margin.
  static const _ttl = Duration(minutes: 15);

  /// Generates a signed JWT for [credentials], valid for [_ttl].
  ///
  /// Tokens are cheap to generate and short-lived by design - callers should
  /// mint a fresh one per request rather than caching across calls.
  static Future<String> generate(AscCredentials credentials) async {
    final privateKey = CryptoUtils.ecPrivateKeyFromPem(
      await credentials.readPrivateKeyPem(),
    );

    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final header = {'alg': 'ES256', 'kid': credentials.keyId, 'typ': 'JWT'};
    final payload = {
      'iss': credentials.issuerId,
      'iat': now,
      'exp': now + _ttl.inSeconds,
      'aud': _audience,
    };

    final signingInput =
        '${_b64(utf8.encode(jsonEncode(header)))}.'
        '${_b64(utf8.encode(jsonEncode(payload)))}';

    final signature = _sign(privateKey, utf8.encode(signingInput));
    return '$signingInput.${_b64(signature)}';
  }

  /// Signs [data] with ES256 (SHA-256/ECDSA over the P-256 curve) and returns
  /// the JWS signature: the raw, fixed-width `r || s` byte concatenation.
  ///
  /// `basic_utils`'s `ecSign` hands back a bare `ECSignature(r, s)` - the
  /// signer's raw output, *not* the ASN.1 DER `SEQUENCE { r, s }` that
  /// `ecSignatureToBase64` would produce. JWS ES256 (RFC 7518 §3.4) wants
  /// neither form as-is: it wants `r` and `s` each zero-padded to the curve's
  /// coordinate size (32 bytes for P-256) and concatenated, with no ASN.1
  /// wrapper at all. So this does the padding/concatenation by hand instead
  /// of using either `ecSign`'s raw ints or `ecSignatureToBase64`'s DER.
  static Uint8List _sign(ECPrivateKey privateKey, List<int> data) {
    final sig = CryptoUtils.ecSign(
      privateKey,
      Uint8List.fromList(data),
      algorithmName: 'SHA-256/ECDSA', // default is SHA-1, wrong for ES256
    );
    return Uint8List.fromList([..._to32Bytes(sig.r), ..._to32Bytes(sig.s)]);
  }

  /// Big-endian, zero-padded to 32 bytes (P-256's coordinate size).
  static Uint8List _to32Bytes(BigInt value) {
    final bytes = Uint8List(32);
    var v = value;
    for (var i = 31; i >= 0 && v > BigInt.zero; i--) {
      bytes[i] = (v & BigInt.from(0xff)).toInt();
      v = v >> 8;
    }
    return bytes;
  }

  /// Unpadded base64url, as JWS requires (RFC 7515 §2).
  static String _b64(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}
