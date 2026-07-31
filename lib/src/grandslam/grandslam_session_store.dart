/// Persistence for the GrandSlam Developer Services session produced by
/// the Apple ID/password flow.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:xcross/src/grandslam/anisette/anisette_state.dart';
import 'package:xcross/src/grandslam/app_token_exchange.dart';
import 'package:xcross/src/util/errors.dart';

class GrandSlamSession {
  const GrandSlamSession({required this.username, required this.token});

  final String username;
  final DeveloperServicesLoginToken token;

  bool get isExpired => token.isExpired;

  Map<String, Object?> toJson() => {
    'username': username,
    'adsid': token.adsid,
    'token': token.token,
    'expiryMs': token.expiry.toUtc().millisecondsSinceEpoch,
  };

  factory GrandSlamSession.fromJson(Map<String, Object?> json) {
    final username = json['username'];
    final adsid = json['adsid'];
    final token = json['token'];
    final expiryMs = json['expiryMs'];
    if (username is! String || username.isEmpty) {
      throw XcrossError('GrandSlam session: missing/invalid "username"');
    }
    if (adsid is! String || adsid.isEmpty) {
      throw XcrossError('GrandSlam session: missing/invalid "adsid"');
    }
    if (token is! String || token.isEmpty) {
      throw XcrossError('GrandSlam session: missing/invalid "token"');
    }
    if (expiryMs is! int) {
      throw XcrossError('GrandSlam session: missing/invalid "expiryMs"');
    }
    return GrandSlamSession(
      username: username,
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
    } on FormatException catch (e) {
      throw XcrossError('$_path: invalid JSON ($e)');
    }
    if (doc is! Map) {
      throw XcrossError('$_path: invalid document');
    }
    return GrandSlamSession.fromJson(doc.cast<String, Object?>());
  }

  Future<void> save(GrandSlamSession session) async {
    final file = File(_path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(session.toJson()),
    );
    if (!Platform.isWindows) {
      try {
        posix.chmod(file.path, '600');
      } on Object catch (e) {
        throw XcrossError(
          'Could not restrict GrandSlam session permissions at $_path: $e',
        );
      }
    }
  }

  Future<void> clear() async {
    final file = File(_path);
    if (file.existsSync()) await file.delete();
  }
}
