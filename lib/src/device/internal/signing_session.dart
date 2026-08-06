import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:meta/meta.dart';

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
}
