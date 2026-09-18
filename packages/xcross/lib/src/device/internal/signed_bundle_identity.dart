import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:xcross/src/errors.dart';

/// The one bundle identity used from provisioning through device launch.
///
/// [exact] is computed once from the requested project id and signing identity.
/// Every operation must carry this value forward rather than qualifying or
/// resolving the identifier again.
final class SignedBundleIdentity {
  SignedBundleIdentity._({required this.requested, required this.exact});

  /// [appIdRegisteredToTeam] keeps the requested id as it is.
  ///
  /// Qualifying exists so two accounts can share a project bundle id without
  /// racing for a globally unique App ID. When the team already owns the App ID
  /// there is nothing to race for, and qualifying actively breaks things that
  /// are bound to the real id: an Apple identity token carries the bundle id as
  /// its `aud`, passkeys and `ASWebAuthenticationSession.Callback.https` are
  /// bound through the App ID's AASA `webcredentials` entry, and push,
  /// Sign in with Apple and Associated Domains are provisioned per App ID.
  factory SignedBundleIdentity.qualify({
    required String requested,
    required String signingIdentityId,
    bool appIdRegisteredToTeam = false,
  }) => SignedBundleIdentity._(
    requested: requested,
    exact: appIdRegisteredToTeam
        ? requested
        : ProvisioningIdentifiers.qualify(requested, signingIdentityId),
  );

  final String requested;
  final String exact;

  /// Proves that the artifact handed to the installer carries [exact].
  ///
  /// Installation consumes the `.app` directory rather than a separate bundle
  /// id argument, so checking its Info.plist immediately before install closes
  /// the only place the planned identity and installed identity could diverge.
  void verifyArtifact(String? artifactBundleId) {
    if (artifactBundleId == exact) return;
    final actual = artifactBundleId == null
        ? 'missing CFBundleIdentifier'
        : '"$artifactBundleId"';
    throw XcrossError(
      'Refusing to install an app whose bundle id changed after signing: '
      'expected "$exact", found $actual.',
    );
  }
}
