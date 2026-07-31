import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/util/errors.dart';

/// App Store Connect API credentials (a Team-scoped API key).
///
/// Loaded from a per-user config file, never from the project's `xtool.yml` -
/// that file is project-local and commonly committed to git, which is the
/// wrong place for secret material.
class AscCredentials {
  const AscCredentials({
    required this.issuerId,
    required this.keyId,
    required this.privateKeyPath,
  });

  /// App Store Connect API "Issuer ID" (one per team).
  final String issuerId;

  /// The API key's "Key ID", shown next to it in App Store Connect.
  final String keyId;

  /// Path to the downloaded `AuthKey_<keyId>.p8` file (PEM EC private key).
  ///
  /// Only the path is stored here, not the key content, so the secret isn't
  /// duplicated between this config file and the `.p8` file Apple gave you.
  final String privateKeyPath;

  /// Reads the `.p8` file's PEM content.
  Future<String> readPrivateKeyPem() => File(privateKeyPath).readAsString();

  /// Default per-user config file location: `%APPDATA%/xcross/appstoreconnect.json`
  /// on Windows, `$XDG_CONFIG_HOME/xcross/appstoreconnect.json` (falling back
  /// to `~/.config/...`) elsewhere.
  static String defaultConfigPath() =>
      p.join(_configDir(), 'xcross', 'appstoreconnect.json');

  static String _configDir() {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) return appData;
    }
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.isNotEmpty) return xdg;
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return p.join(home, '.config');
  }

  /// Loads credentials from [path] (defaults to [defaultConfigPath]).
  static Future<AscCredentials> fromFile([String? path]) async {
    final file = File(path ?? defaultConfigPath());
    if (!file.existsSync()) {
      throw XcrossError(
        'App Store Connect credentials not found at ${file.path}.\n'
        'Create it with: {"issuerId": "...", "keyId": "...", '
        '"privateKeyPath": "/path/to/AuthKey_<keyId>.p8"}',
      );
    }
    final Object? doc;
    try {
      doc = jsonDecode(await file.readAsString());
    } on FormatException catch (e) {
      throw XcrossError('${file.path}: invalid JSON ($e)');
    }
    if (doc is! Map) {
      throw XcrossError('${file.path}: invalid document');
    }
    final issuerId = doc['issuerId'] as String?;
    final keyId = doc['keyId'] as String?;
    final privateKeyPath = doc['privateKeyPath'] as String?;
    if (issuerId == null || keyId == null || privateKeyPath == null) {
      throw XcrossError(
        '${file.path}: must specify issuerId, keyId, and privateKeyPath',
      );
    }
    return AscCredentials(
      issuerId: issuerId,
      keyId: keyId,
      privateKeyPath: privateKeyPath,
    );
  }
}
