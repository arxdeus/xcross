import 'package:apple_developer_kit/apple_developer_kit_shared.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// An authenticated provisioning client plus the on-disk locations derived
/// from whichever identity (Apple ID team or ASC issuer) it authenticated as.
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
