/// Persistence for the GrandSlam Developer Services session produced by
/// the Apple ID/password flow.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:apple_developer_kit/src/grandslam/anisette/anisette_state.dart';
import 'package:apple_developer_kit/src/grandslam/app_token_exchange.dart';
import 'package:apple_developer_kit/src/errors.dart';

class GrandSlamSession {
  GrandSlamSession({
    required this.username,
    required this.token,
    required this.teamId,
    this.adiLibraryDirectory,
  }) {
    if (adiLibraryDirectory != null && !p.isAbsolute(adiLibraryDirectory!)) {
      throw AppleError(
        'GrandSlam session: "adiLibraryDirectory" must be absolute',
      );
    }
  }

  final String username;
  final DeveloperServicesLoginToken token;
  final String teamId;

  /// Absolute directory containing Android ADI libraries
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

  factory GrandSlamSession.fromJson(Map<String, Object?> json) {
    final username = json['username'];
    final adsid = json['adsid'];
    final token = json['token'];
    final expiryMs = json['expiryMs'];
    final teamId = json['teamId'];
    final adiLibraryDirectory = json['adiLibraryDirectory'];
    if (username is! String || username.isEmpty) {
      throw AppleError('GrandSlam session: missing/invalid "username"');
    }
    if (adsid is! String || adsid.isEmpty) {
      throw AppleError('GrandSlam session: missing/invalid "adsid"');
    }
    if (token is! String || token.isEmpty) {
      throw AppleError('GrandSlam session: missing/invalid "token"');
    }
    if (expiryMs is! int) {
      throw AppleError('GrandSlam session: missing/invalid "expiryMs"');
    }
    if (teamId is! String || teamId.isEmpty) {
      throw AppleError('GrandSlam session: missing/invalid "teamId"');
    }
    if (adiLibraryDirectory != null &&
        (adiLibraryDirectory is! String ||
            !p.isAbsolute(adiLibraryDirectory))) {
      throw AppleError('GrandSlam session: invalid "adiLibraryDirectory"');
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
}

class GrandSlamSessionStore {
  GrandSlamSessionStore({String? path}) : _path = path ?? defaultPath();

  final String _path;

  String get path => _path;

  static String defaultPath() => p.join(
    p.dirname(AnisetteStateStore.defaultPath()),
    'grandslam-session.json',
  );

  Future<GrandSlamSession?> load() async {
    final file = File(_path);
    if (!file.existsSync()) return null;

    final Object? doc;
    try {
      doc = jsonDecode(await file.readAsString());
    } on FormatException {
      throw AppleError('$_path: invalid JSON');
    }
    if (doc is! Map) {
      throw AppleError('$_path: invalid document');
    }
    return GrandSlamSession.fromJson(doc.cast<String, Object?>());
  }

  Future<void> save(GrandSlamSession session) async {
    final file = File(_path);
    await file.parent.create(recursive: true);
    final contents = const JsonEncoder.withIndent(
      '  ',
    ).convert(session.toJson());

    final temporary = File('$_path.${generateUuidV4()}.tmp');
    try {
      await temporary.writeAsString(contents, flush: true);
      if (!Platform.isWindows) posix.chmod(temporary.path, '600');
      await temporary.rename(file.path);
    } on Object catch (e) {
      if (temporary.existsSync()) await temporary.delete();
      throw AppleError('Could not save GrandSlam session at $_path: $e');
    }
  }

  Future<void> clear() async {
    final file = File(_path);
    if (file.existsSync()) await file.delete();
  }
}
