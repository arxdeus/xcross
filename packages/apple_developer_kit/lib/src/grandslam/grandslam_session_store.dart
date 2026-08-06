/// Persistence for the GrandSlam Developer Services session produced by
/// the Apple ID/password flow.
library;

import 'dart:convert';
import 'dart:io';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/anisette_state.dart';
import 'package:apple_developer_kit/src/grandslam/app_token_exchange.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;

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

final class GrandSlamSessionStore {
  GrandSlamSessionStore({String? path}) : path = path ?? defaultPath();

  final String path;

  @useResult
  static String defaultPath() => p.join(
    p.dirname(AnisetteStateStore.defaultPath()),
    'grandslam-session.json',
  );

  Future<GrandSlamSession?> load() async {
    final file = File(path);
    if (!file.existsSync()) return null;

    final Object? doc;
    try {
      doc = jsonDecode(await file.readAsString());
    } on FormatException {
      // Deliberately does not echo the exception: the file holds a token.
      throw AppleError('$path: invalid JSON');
    }
    if (doc is! Map) throw AppleError('$path: invalid document');
    return GrandSlamSession.fromJson(doc.cast<String, Object?>());
  }

  /// Writes atomically through a temporary file so a crash mid-write
  /// cannot leave a half-written session behind, and restricts the file
  /// to the owner wherever POSIX permissions exist.
  Future<void> save(GrandSlamSession session) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final contents = const JsonEncoder.withIndent(
      '  ',
    ).convert(session.toJson());

    final temporary = File('$path.${AnisetteState.generateUuidV4()}.tmp');
    try {
      await temporary.writeAsString(contents, flush: true);
      if (!Platform.isWindows) posix.chmod(temporary.path, '600');
      await temporary.rename(file.path);
    } on Object catch (e) {
      if (temporary.existsSync()) await temporary.delete();
      throw AppleError('Could not save GrandSlam session at $path: $e');
    }
  }

  Future<void> clear() async {
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }
}
