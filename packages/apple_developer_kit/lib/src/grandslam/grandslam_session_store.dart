/// Persistence for the GrandSlam Developer Services session produced by
/// the Apple ID/password flow.
library;

import 'dart:convert';
import 'dart:io';
import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/anisette_state.dart';
import 'package:apple_developer_kit/src/grandslam/app_token_exchange.dart';
import 'package:apple_developer_kit/src/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/src/secure/local_cipher.dart';
import 'package:apple_developer_kit/src/secure/secure_file.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

@immutable
final class GrandSlamSession {
  GrandSlamSession({
    required this.username,
    required this.token,
    required this.teamId,
    this.adiLibraryDirectory,
  }) {
    final directory = adiLibraryDirectory;
    if (directory != null && !p.isAbsolute(directory)) {
      throw const AppleError(
        'GrandSlam session: "adiLibraryDirectory" must be absolute',
      );
    }
  }

  factory GrandSlamSession.fromJson(Map<String, Object?> json) {
    String required(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw AppleError('GrandSlam session: missing/invalid "$key"');
      }
      return value;
    }

    final username = required('username');
    final adsid = required('adsid');
    final token = required('token');
    final expiryMs = json['expiryMs'];
    if (expiryMs is! int) {
      throw const AppleError('GrandSlam session: missing/invalid "expiryMs"');
    }
    final teamId = required('teamId');
    final adiLibraryDirectory = json['adiLibraryDirectory'];
    if (adiLibraryDirectory != null &&
        (adiLibraryDirectory is! String ||
            !p.isAbsolute(adiLibraryDirectory))) {
      throw const AppleError(
        'GrandSlam session: invalid "adiLibraryDirectory"',
      );
    }

    return GrandSlamSession(
      username: username,
      teamId: teamId,
      adiLibraryDirectory: adiLibraryDirectory as String?,
      token: DeveloperServicesLoginToken(
        adsid: adsid,
        token: token,
        expiry: DateTime.fromMillisecondsSinceEpoch(expiryMs, isUtc: true),
      ),
    );
  }

  final String username;
  final DeveloperServicesLoginToken token;
  final String teamId;

  /// Absolute directory holding the Android ADI libraries
  /// (`libCoreADI.so`, `libstoreservicescore.so`) used for Anisette.
  final String? adiLibraryDirectory;

  bool get isExpired => token.isExpired;

  Map<String, Object?> toJson() => {
    'username': username,
    'adsid': token.adsid,
    'token': token.token,
    'expiryMs': token.expiry.toUtc().millisecondsSinceEpoch,
    'teamId': teamId,
    if (adiLibraryDirectory != null) 'adiLibraryDirectory': adiLibraryDirectory,
  };
}

/// Reads/writes the [GrandSlamSession] as an encrypted, owner-only file.
///
/// The session is sealed with [LocalCipher], so the token is not sitting in
/// cleartext in a directory that routinely ends up in backups and synced
/// dotfile folders. Sealing is safe here precisely because the session is
/// re-obtainable: if the key file or the machine changes, [load] reports
/// the session as unreadable and `xcross auth` mints a new one.
final class GrandSlamSessionStore {
  GrandSlamSessionStore({
    required AppleHostServices hostServices,
    String? path,
    LocalCipher? cipher,
  }) : hostServices = hostServices,
       path = path ?? defaultPath(hostServices: hostServices),
       _cipher = cipher ?? LocalCipher(hostServices: hostServices);

  final AppleHostServices hostServices;

  final String path;
  final LocalCipher _cipher;

  @useResult
  static String defaultPath({required AppleHostServices hostServices}) =>
      p.join(
        p.dirname(AnisetteStateStore.defaultPath(hostServices: hostServices)),
        'grandslam-session.json',
      );

  /// Returns null when no session is stored.
  ///
  /// A file left over from before sessions were encrypted is read as
  /// plaintext once and immediately rewritten sealed, so the cleartext
  /// token stops existing on disk without forcing a re-login.
  Future<GrandSlamSession?> load() async {
    final file = File(path);
    if (!file.existsSync()) return null;

    final contents = await file.readAsString();
    if (!LocalCipher.isSealed(contents)) {
      final migrated = _parse(contents);
      await save(migrated);
      return migrated;
    }
    return _parse(await _cipher.open(contents));
  }

  GrandSlamSession _parse(String json) {
    final Object? doc;
    try {
      doc = jsonDecode(json);
    } on FormatException {
      // Deliberately does not echo the exception: the file holds a token.
      throw AppleError('$path: invalid JSON');
    }
    if (doc is! Map) throw AppleError('$path: invalid document');
    return GrandSlamSession.fromJson(doc.cast<String, Object?>());
  }

  Future<void> save(GrandSlamSession session) async {
    await SecureFile(
      hostServices: hostServices,
    ).writeString(path, await _cipher.seal(jsonEncode(session.toJson())));
  }

  Future<void> clear() async {
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }
}
