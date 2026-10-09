import 'package:apple_developer_kit/shared/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/anisette_provider.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// An authenticated provisioning client plus the on-disk locations derived
/// from whichever identity (Apple ID team or ASC issuer) it authenticated as.
@internal
@immutable
final class SigningSession {
  const SigningSession({
    required this.client,
    required this.anisette,
    required this.identityId,
    required this.identityDir,
  });

  final DevelopmentProvisioningClient client;
  final AnisetteProvider? anisette;
  final String identityId;
  final String identityDir;

  SigningIdentity get identity =>
      SigningIdentity(identityId: identityId, identityDir: identityDir);

  /// `<config-dir>/xcross/signing` — root of every certificate, private key,
  /// and provisioning profile xcross has minted, one subtree per identity.
  @useResult
  static String signingRoot(String configDirectory) =>
      p.join(configDirectory, 'signing');

  /// `<signing-root>/<account>/identity`, where the account's certificate and
  /// its private key are cached for reuse across builds.
  @useResult
  static String identityDirFor(String configDirectory, String account) =>
      p.join(signingRoot(configDirectory), account, 'identity');
}

/// Who signs, and where their cached certificate lives, without any client to
/// talk to Apple. Enough to sign offline with what an earlier run cached.
@internal
@immutable
final class SigningIdentity {
  const SigningIdentity({required this.identityId, required this.identityDir});

  final String identityId;

  /// See [SigningSession.identityDirFor].
  final String identityDir;

  /// `<signing-root>/<account>/profiles`, one directory per signed bundle id.
  String get profilesDir => p.join(p.dirname(identityDir), 'profiles');
}
