/// The result of a successful GrandSlam SRP login handshake
/// ([GrandSlamClient.login], `grandslam_login.dart`): the adsid/token/
/// session-key layer 2c (a later, separate task) will exchange for a
/// Developer-Services app token via `o=apptokens` - not implemented here.
///
/// Matches xtool's `GrandSlamLoginData` (`Sources/XKit/GrandSlam/Model/
/// GrandSlamLoginData.swift`), decoded from the same decrypted `o=complete`
/// `spd` payload.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:xcross/src/grandslam/grandslam_response.dart';

class GrandSlamLoginData {
  const GrandSlamLoginData({
    required this.adsid,
    required this.idmsToken,
    required this.sessionKey,
    required this.cookie,
  });

  /// Decodes a [GrandSlamLoginData] from the decrypted `o=complete` `spd`
  /// payload (a bare plist dict, no `Status`/`Response` envelope). Matches
  /// xtool's `Decodable` field names exactly: `adsid`, `GsIdmsToken`, `sk`,
  /// `c` (a *binary* cookie here - distinct from `o=init`'s string `c`
  /// cookie used to correlate the `o=complete` request).
  factory GrandSlamLoginData.fromDecryptedPlist(Map<String, Object?> plist) {
    return GrandSlamLoginData(
      adsid: stringField(plist, 'adsid'),
      idmsToken: stringField(plist, 'GsIdmsToken'),
      sessionKey: dataField(plist, 'sk'),
      cookie: dataField(plist, 'c'),
    );
  }

  final String adsid;
  final String idmsToken;
  final Uint8List sessionKey;
  final Uint8List cookie;

  /// `base64("$adsid:$idmsToken")` - the `X-Apple-Identity-Token` header
  /// value required on every two-factor-authentication request.
  String get identityToken => base64Encode(utf8.encode('$adsid:$idmsToken'));
}
