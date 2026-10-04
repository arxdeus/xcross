import 'package:meta/meta.dart';

/// The identifiers a provisioning profile contributes to a signature.
@immutable
final class ProfileIdentity {
  const ProfileIdentity({
    required this.teamIdentifier,
    required this.entitlements,
    required this.applicationIdentifier,
    required this.applicationIdentifierPrefix,
  });

  final String teamIdentifier;
  final Map<String, Object?> entitlements;
  final String applicationIdentifier;
  final String applicationIdentifierPrefix;
}
