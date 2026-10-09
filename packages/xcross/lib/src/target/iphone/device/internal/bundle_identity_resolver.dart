import 'package:apple_developer_kit/shared/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/provisioning_identifiers.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/cli/command_prompt.dart';
import 'package:xcross/src/shared/config/project_settings.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/target/iphone/device/internal/signed_bundle_identity.dart';

/// Which App ID an app is signed under.
@internal
enum BundleIdMode {
  /// `XCR-<identity>.<bundle id>`: never collides with another team.
  prefixed,

  /// The project's own bundle id, as written.
  original;

  static BundleIdMode? tryParse(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'prefixed' => prefixed,
        'original' => original,
        _ => null,
      };
}

/// Decides the App ID an app is signed under.
///
/// In order:
///
/// 1. `XCROSS_BUNDLE_ID`, for a one-off override (CI, IDE sessions).
/// 2. `bundle_id` in the project settings (`xcross_project.yaml`, or the
///    `xcross:` section of `pubspec.yaml`): the choice committed with the
///    project.
/// 3. An App ID the team already owns, in either form: the choice an earlier
///    build made before it was recorded. Switching would orphan the app's
///    data and every capability bound to that App ID.
/// 4. Otherwise this is the app's first build, the one moment the choice is
///    free, so the user is asked and the answer is saved to the project.
///    Without a terminal the prefixed form is used and nothing is saved.
@internal
final class BundleIdentityResolver {
  BundleIdentityResolver({
    required this.client,
    required this.log,
    required this.prompt,
    required this.environment,
    this.settings,
  });

  /// Overrides the choice for one run: `original` or `prefixed`.
  static const modeVariable = 'XCROSS_BUNDLE_ID';

  /// Project settings key holding the saved choice.
  static const settingKey = 'bundle_id';

  final DevelopmentProvisioningClient client;
  final Log log;
  final CommandPrompt? prompt;
  final Map<String, String> environment;

  /// Where the choice is saved; `null` when the project root is unknown.
  final ProjectSettings? settings;

  Future<SignedBundleIdentity> resolve({
    required String requested,
    required String signingIdentityId,
  }) async {
    final prefixed = SignedBundleIdentity.qualify(
      requested: requested,
      signingIdentityId: signingIdentityId,
    );
    final original = SignedBundleIdentity.qualify(
      requested: requested,
      signingIdentityId: signingIdentityId,
      appIdRegisteredToTeam: true,
    );

    final chosen = _forced() ?? _saved();
    if (chosen != null) {
      return switch (chosen) {
        BundleIdMode.prefixed => prefixed,
        BundleIdMode.original =>
          await _claimOriginal(requested) ? original : prefixed,
      };
    }

    if (await client.findBundleId(requested) != null) return original;
    if (await client.findBundleId(prefixed.exact) != null) return prefixed;

    final asked = _ask(requested: requested, prefixed: prefixed.exact);
    if (asked == null) return prefixed;
    // Save what was actually registered: an original id another team owns
    // falls back to prefixed, and retrying it on every build would only
    // repeat the same failure.
    final effective =
        asked == BundleIdMode.original && await _registerOriginal(requested)
        ? BundleIdMode.original
        : BundleIdMode.prefixed;
    await _save(effective);
    return effective == BundleIdMode.original ? original : prefixed;
  }

  BundleIdMode? _forced() {
    final raw = environment[modeVariable];
    if (raw == null || raw.trim().isEmpty) return null;
    return BundleIdMode.tryParse(raw) ??
        (throw XcrossError(
          '$modeVariable must be "original" or "prefixed", not "${raw.trim()}".',
        ));
  }

  BundleIdMode? _saved() {
    final settings = this.settings;
    if (settings == null) return null;
    final raw = settings.read(settingKey);
    if (raw == null) return null;
    return BundleIdMode.tryParse(raw) ??
        (throw XcrossError(
          '${settings.path}: $settingKey must be "original" or "prefixed", '
          'not "${raw.trim()}".',
        ));
  }

  /// `null` when nobody can be asked.
  BundleIdMode? _ask({required String requested, required String prefixed}) {
    final prompt = this.prompt;
    // A DAP session speaks its protocol over stdin, so it is never asked.
    final canAsk =
        prompt != null &&
        prompt.isInteractive &&
        environment['XCROSS_DAP'] != '1';
    if (!canAsk) return null;

    final saveNote = switch (settings) {
      final settings? => ' The answer is saved to ${settings.path}.',
      null => '',
    };
    prompt.write(
      'First build of $requested on this team. Which App ID should xcross '
      'register?$saveNote\n'
      '  [1] $prefixed  (prefixed, never collides with another team)\n'
      '  [2] $requested  (original, needed for Sign in with Apple, push, '
      'passkeys and associated domains)\n',
    );
    while (true) {
      final raw = prompt.readLine('Choose 1 or 2 [1]: ');
      if (raw == null) return null;
      switch (raw.trim().toLowerCase()) {
        case '' || '1' || 'prefixed':
          return BundleIdMode.prefixed;
        case '2' || 'original':
          return BundleIdMode.original;
      }
      prompt.write('Invalid choice "${raw.trim()}".\n');
    }
  }

  Future<void> _save(BundleIdMode mode) async {
    final settings = this.settings;
    if (settings == null) return;
    try {
      await settings.write(settingKey, mode.name);
      log.logInfo(
        'Saved',
        '$settingKey: ${mode.name} ${log.dim(settings.path)}',
      );
    } on Object catch (error) {
      log.logWarn(
        'Could not save $settingKey to ${settings.path} ($error); '
        'you will be asked again next time.',
      );
    }
  }

  Future<bool> _claimOriginal(String requested) async =>
      await client.findBundleId(requested) != null ||
      await _registerOriginal(requested);

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
