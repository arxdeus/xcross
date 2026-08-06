/// The result of a successful GrandSlam SRP login handshake
/// ([GrandSlamClient.login]), decoded from the decrypted `o=complete`
/// `spd` payload. [GrandSlamAppTokenExchange] turns it into a Developer
/// Services app token.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/grandslam/internal/grandslam_response_decoder.dart';
import 'package:meta/meta.dart';

@immutable
final class GrandSlamLoginData {
  const GrandSlamLoginData({
    required this.adsid,
    required this.idmsToken,
    required this.sessionKey,
    required this.cookie,
  });

  /// Decodes the decrypted `spd` payload - a bare plist dict with no
  /// `Status`/`Response` envelope. Field names match xtool's
  /// `GrandSlamLoginData` exactly. Note `c` here is a *binary* cookie,
  /// distinct from `o=init`'s string `c` that correlates `o=complete`.
  factory GrandSlamLoginData.fromDecryptedPlist(Map<String, Object?> plist) =>
      GrandSlamLoginData(
        adsid: GrandSlamResponse.stringField(plist, 'adsid'),
        idmsToken: GrandSlamResponse.stringField(plist, 'GsIdmsToken'),
        sessionKey: GrandSlamResponse.dataField(plist, 'sk'),
        cookie: GrandSlamResponse.dataField(plist, 'c'),
      );

  final String adsid;
  final String idmsToken;
  final Uint8List sessionKey;
  final Uint8List cookie;

  /// `base64("$adsid:$idmsToken")` - the `X-Apple-Identity-Token` header
  /// value every two-factor request must carry.
  String get identityToken => base64Encode(utf8.encode('$adsid:$idmsToken'));
}
