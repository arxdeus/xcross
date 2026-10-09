import 'package:apple_developer_kit/shared/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/provisioning_identifiers.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/cli/command_prompt.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/target/iphone/device/internal/signed_bundle_identity.dart';

/// Which App ID a first build registers.
@internal
enum BundleIdMode {
  /// `XCR-<identity>.<bundle id>`: never collides with another team.
  prefixed,

  /// The project's own bundle id, as written.
  original;

  static BundleIdMode? tryParse(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'prefixed' || 'prefix' || 'xcr' => prefixed,
        'original' || 'bundle' || 'plain' => original,
        _ => null,
      };
}

/// Decides the App ID an app is signed under.
///
/// An App ID the team already owns, under either form, is reused silently: it
/// is the choice made on an earlier build, and switching would orphan the
/// app's data and every capability bound to that App ID. Only when neither
/// exists (the app's first build on this team) is the user asked, because it
/// is the one moment the choice is free.
@internal
final class BundleIdentityResolver {
  BundleIdentityResolver({
    required this.client,
    required this.log,
    required this.prompt,
    required this.environment,
  });

  /// Forces the first-build choice without a prompt: `original` or
  /// `prefixed`. Needed in CI and DAP sessions, which cannot be asked.
  static const modeVariable = 'XCROSS_BUNDLE_ID';

  final DevelopmentProvisioningClient client;
  final Log log;
  final CommandPrompt? prompt;
  final Map<String, String> environment;

  Future<SignedBundleIdentity> resolve({
    required String requested,
    required String signingIdentityId,
  }) async {
    SignedBundleIdentity prefixed() => SignedBundleIdentity.qualify(
      requested: requested,
      signingIdentityId: signingIdentityId,
    );
    SignedBundleIdentity original() => SignedBundleIdentity.qualify(
      requested: requested,
      signingIdentityId: signingIdentityId,
      appIdRegisteredToTeam: true,
    );

    if (await client.findBundleId(requested) != null) return original();
    final qualified = prefixed();
    if (await client.findBundleId(qualified.exact) != null) return qualified;

    final mode = _chooseMode(requested: requested, prefixed: qualified.exact);
    if (mode == BundleIdMode.prefixed) return qualified;
    return await _registerOriginal(requested) ? original() : qualified;
  }

  BundleIdMode _chooseMode({
    required String requested,
    required String prefixed,
  }) {
    final raw = environment[modeVariable];
    if (raw != null && raw.trim().isNotEmpty) {
      final forced = BundleIdMode.tryParse(raw);
      if (forced == null) {
        throw XcrossError(
          '$modeVariable must be "original" or "prefixed", not "${raw.trim()}".',
        );
      }
      return forced;
    }
    final prompt = this.prompt;
    // A DAP session speaks its protocol over stdin, so it is never asked.
    final canAsk =
        prompt != null &&
        prompt.isInteractive &&
        environment['XCROSS_DAP'] != '1';
    if (!canAsk) return BundleIdMode.prefixed;

    prompt.write(
      'First build of $requested on this team. Which App ID should xcross '
      'register?\n'
      '  [1] $prefixed  (prefixed, never collides with another team)\n'
      '  [2] $requested  (original, needed for Sign in with Apple, push, '
      'passkeys and associated domains)\n',
    );
    while (true) {
      final raw = prompt.readLine('Choose 1 or 2 [1]: ');
      if (raw == null) return BundleIdMode.prefixed;
      switch (raw.trim().toLowerCase()) {
        case '' || '1' || 'p' || 'prefixed':
          return BundleIdMode.prefixed;
        case '2' || 'o' || 'original':
          return BundleIdMode.original;
      }
      prompt.write('Invalid choice "${raw.trim()}".\n');
    }
  }

  /// Claims [requested] now, so a bundle id another team already owns falls
  /// back to the prefixed form instead of failing deep inside provisioning.
  Future<bool> _registerOriginal(String requested) async {
    try {
      await client.registerBundleId(
        identifier: requested,
        name: ProvisioningIdentifiers.appName(requested),
      );
      return true;
    } on AppleApiError catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) rethrow;
      log.logWarn(
        'Could not register $requested (${error.message}); it is likely '
        'owned by another team. Using the prefixed App ID instead.',
      );
      return false;
    }
  }
}
