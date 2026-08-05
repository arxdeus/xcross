/// Per-account App ID uniquifiers, matching xtool's `ProvisioningIdentifiers`
/// (`XTL-…` there; `XCR-…` here).
///
/// Free (and often paid) teams cannot share an explicit App ID. Qualifying
/// `com.example.Hello` as `XCR-<IDENTITY>.com.example.Hello` lets two accounts
/// keep the same project bundle id without colliding at registration time.
abstract final class ProvisioningIdentifiers {
  static const idPrefix = 'XCR-';
  static const namePrefix = 'xcross ';

  /// Strips a leading `XCR-<segment>.` if present.
  static String sanitize(String identifier) {
    if (!identifier.startsWith(idPrefix)) return identifier;
    final dot = identifier.indexOf('.');
    return dot < 0 ? identifier : identifier.substring(dot + 1);
  }

  /// `XCR-<first segment of identityId>.<sanitized identifier>`.
  ///
  /// [identityId] is the Apple team id (GrandSlam) or ASC issuer UUID — same
  /// sources xtool uses for `DeveloperAPIAuthData.identityID`.
  static String qualify(String identifier, String identityId) {
    final sanitized = sanitize(identifier);
    final segment = identityId.split('-').first.toUpperCase();
    return '$idPrefix$segment.$sanitized';
  }

  /// Portal display name for a (possibly already-qualified) bundle id.
  /// Apple rejects anything but letters, digits, and spaces here.
  static String appName(String identifier) {
    final words = sanitize(
      identifier,
    ).replaceAll(RegExp('[^A-Za-z0-9]+'), ' ').trim();
    return '$namePrefix$words';
  }
}
