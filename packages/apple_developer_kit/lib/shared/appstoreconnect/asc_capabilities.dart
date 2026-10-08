/// Which App Store Connect **capabilities** an app's entitlements require.
///
/// A provisioning profile only grants what the App ID has switched on, and the
/// signer takes its entitlements from the profile (`SigningAsset`). An app that
/// declares `com.apple.developer.applesignin` in its entitlements file therefore
/// gets a profile without it, and the ceremony fails at runtime with nothing in
/// the build log to explain it: Sign in with Apple refuses to present, or
/// `ASWebAuthenticationSession.Callback.https` fails instantly with "Login was
/// cancelled" because iOS cannot verify the app owns the callback host.
///
/// This is the mapping from the entitlement keys a project declares to the
/// capability types `/v1/bundleIdCapabilities` accepts.
library;

/// Maps entitlement keys to App Store Connect `capabilityType` values.
abstract final class AscCapabilities {
  /// Capability type for each entitlement key that needs one.
  ///
  /// Keys deliberately absent are the ones that are not capabilities:
  /// `application-identifier`, `com.apple.developer.team-identifier`,
  /// `get-task-allow`, `keychain-access-groups`, `beta-reports-active` and
  /// friends are supplied by the profile itself, and asking Apple to "enable"
  /// them is rejected.
  static const byEntitlementKey = <String, String>{
    // Push. `development` for debug builds, `production` for distribution; the
    // capability itself is the same either way.
    'aps-environment': 'PUSH_NOTIFICATIONS',
    // Sign in with Apple.
    'com.apple.developer.applesignin': 'APPLE_ID_AUTH',
    // Universal links, passkeys and https auth-session callbacks.
    'com.apple.developer.associated-domains': 'ASSOCIATED_DOMAINS',
    // App Groups. Apple's API can switch this capability on but cannot attach a
    // group to it - see `AscClient.findAppGroup`.
    'com.apple.security.application-groups': 'APP_GROUPS',
    'com.apple.developer.in-app-payments': 'APPLE_PAY',
    'com.apple.developer.healthkit': 'HEALTHKIT',
    'com.apple.developer.homekit': 'HOMEKIT',
    'com.apple.developer.icloud-container-identifiers': 'ICLOUD',
    'com.apple.developer.ubiquity-kvstore-identifier': 'ICLOUD',
    'com.apple.developer.game-center': 'GAME_CENTER',
    'com.apple.developer.networking.wifi-info': 'ACCESS_WIFI_INFORMATION',
    'com.apple.developer.siri': 'SIRIKIT',
    'com.apple.developer.pass-type-identifiers': 'WALLET',
    'com.apple.developer.networking.multipath': 'MULTIPATH',
    'com.apple.developer.networking.networkextension': 'NETWORK_EXTENSIONS',
    'com.apple.developer.nfc.readersession.formats': 'NFC_TAG_READING',
  };

  /// The capability types [entitlements] requires, sorted and de-duplicated.
  ///
  /// [entitlements] is a project's parsed `.entitlements` dictionary: values are
  /// ignored, because presence of the key is what the capability is about (an
  /// empty `associated-domains` array still needs the capability before a
  /// profile will carry it).
  static List<String> forEntitlements(Map<String, Object?> entitlements) =>
      forKeys(entitlements.keys);

  /// The capability types [keys] require, sorted and de-duplicated.
  static List<String> forKeys(Iterable<String> keys) {
    final types = <String>{
      for (final key in keys)
        if (byEntitlementKey[key] case final String type) type,
    }.toList()..sort();
    return types;
  }
}
