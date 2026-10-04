import 'dart:convert';

import 'package:apple_developer_kit/src/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/src/shared/config/config_dir.dart';
import 'package:apple_developer_kit/src/shared/errors/errors.dart';
import 'package:apple_developer_kit/src/shared/secure/secure_file.dart';
import 'package:meta/meta.dart';

/// App Store Connect API credentials (a Team-scoped API key).
///
/// Loaded from a per-user config file, never from the project tree —
/// project files are commonly committed to git, which is the wrong place for
/// secret material.
@immutable
final class AscCredentials {
  const AscCredentials({
    required this.hostServices,
    required this.issuerId,
    required this.keyId,
    required this.privateKeyPath,
  });

  /// App Store Connect API "Issuer ID" (one per team).
  final AppleHostServices hostServices;
  final String issuerId;

  /// The API key's "Key ID", shown next to it in App Store Connect.
  final String keyId;

  /// Path to the downloaded `AuthKey_<keyId>.p8` file (PEM EC private key).
  ///
  /// Only the path is stored here, not the key content, so the secret isn't
  /// duplicated between this config file and the `.p8` file Apple gave you.
  final String privateKeyPath;

  /// Reads the `.p8` file's PEM content.
  Future<String> readPrivateKeyPem() =>
      hostServices.host.fileSystem.file(privateKeyPath).readAsString();

  /// Default per-user config file location,
  /// `<config-dir>/xcross/appstoreconnect.json` — see [xcrossConfigDir].
  static String defaultConfigPath({required AppleHostServices hostServices}) =>
      hostServices.host.paths.context.join(
        xcrossConfigDir(hostServices: hostServices),
        'appstoreconnect.json',
      );

  /// Writes these credentials to [path] as an owner-only file.
  ///
  /// Not encrypted with `LocalCipher`, unlike the GrandSlam session: this
  /// file holds identifiers and a path, while the actual secret is the
  /// `.p8` it points at, which the user manages and which
  /// [AscCsr.writePrivateKeyPem] already restricts to its owner.
  Future<void> save({String? path}) =>
      SecureFile(hostServices: hostServices).writeString(
        path ?? defaultConfigPath(hostServices: hostServices),
        const JsonEncoder.withIndent('  ').convert({
          'issuerId': issuerId,
          'keyId': keyId,
          'privateKeyPath': privateKeyPath,
        }),
      );

  /// Loads credentials from [path] (defaults to [defaultConfigPath]).
}

final class AscCredentialsLoader {
  AscCredentialsLoader({required this.hostServices});

  final AppleHostServices hostServices;

  Future<AscCredentials> load({String? path}) async {
    final file = hostServices.host.fileSystem.file(
      path ?? AscCredentials.defaultConfigPath(hostServices: hostServices),
    );
    if (!file.existsSync()) {
      throw AppleError(
        'App Store Connect credentials not found at ${file.path}.\n'
        'Create it with: {"issuerId": "...", "keyId": "...", '
        '"privateKeyPath": "/path/to/AuthKey_<keyId>.p8"}',
      );
    }
    // Repairs configs written by older xcross versions, or hand-created
    // with a permissive umask.
    SecureFile(hostServices: hostServices).harden(file.path);
    final Object? doc;
    try {
      doc = jsonDecode(await file.readAsString());
    } on FormatException catch (e) {
      throw AppleError('${file.path}: invalid JSON ($e)');
    }
    if (doc is! Map) {
      throw AppleError('${file.path}: invalid document');
    }
    final issuerId = doc['issuerId'] as String?;
    final keyId = doc['keyId'] as String?;
    final privateKeyPath = doc['privateKeyPath'] as String?;
    if (issuerId == null || keyId == null || privateKeyPath == null) {
      throw AppleError(
        '${file.path}: must specify issuerId, keyId, and privateKeyPath',
      );
    }
    return AscCredentials(
      hostServices: hostServices,
      issuerId: issuerId,
      keyId: keyId,
      privateKeyPath: privateKeyPath,
    );
  }
}
