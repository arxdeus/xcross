/// Per-account App ID uniquifiers, matching xtool's `ProvisioningIdentifiers`
/// (`XTL-…` there; `XCR-…` here).
///
/// Free (and often paid) teams cannot share an explicit App ID. Qualifying
/// `com.example.Hello` as `XCR-<IDENTITY>.com.example.Hello` lets two accounts
/// keep the same project bundle id without colliding at registration time.
library;

import 'package:meta/meta.dart';

abstract final class ProvisioningIdentifiers {
  static const idPrefix = 'XCR-';
  static const namePrefix = 'xcross ';

  /// Strips a leading `XCR-<segment>.` if present.
  @useResult
  static String sanitize(String identifier) {
    if (!identifier.startsWith(idPrefix)) return identifier;
    final dot = identifier.indexOf('.');
    return dot < 0 ? identifier : identifier.substring(dot + 1);
  }

  /// `XCR-<first segment of identityId>.<sanitized identifier>`.
  ///
  /// [identityId] is the Apple team id (GrandSlam) or ASC issuer UUID — same
  /// sources xtool uses for `DeveloperAPIAuthData.identityID`.
  @useResult
  static String qualify(String identifier, String identityId) {
    final sanitized = sanitize(identifier);
    final segment = identityId.split('-').first.toUpperCase();
    return '$idPrefix$segment.$sanitized';
  }

  /// `group.XCR-<identity>.<rest>` for an App Group identifier.
  ///
  /// App Group ids share one global namespace with every other developer, so
  /// a project's literal `group.com.example.Shared` is usually already taken
  /// (Apple answers HTTP 409 "not available"). The same per-account
  /// qualification used for App IDs is applied after the mandatory `group.`
  /// prefix, which Apple requires to come first.
  @useResult
  static String qualifyAppGroup(String identifier, String identityId) {
    const groupPrefix = 'group.';
    final body = identifier.startsWith(groupPrefix)
        ? identifier.substring(groupPrefix.length)
        : identifier;
    return '$groupPrefix${qualify(body, identityId)}';
  }

  /// Portal display name for a (possibly already-qualified) bundle id.
  /// Apple rejects anything but letters, digits, and spaces here.
  @useResult
  static String appName(String identifier) {
    final words = sanitize(
      identifier,
    ).replaceAll(RegExp('[^A-Za-z0-9]+'), ' ').trim();
    return '$namePrefix$words';
  }

  /// Whether [identifier] is an xcross-qualified form of [base]
  /// (`XCR-<identity>.<base>`).
  ///
  /// Deliberately strict: a device can carry the user's *production* build
  /// under the bare `base` id, and that one is signed without
  /// `get-task-allow`. Treating it as xcross' app makes the debugger fail
  /// with "Permission to debug … was denied".
  @useResult
  static bool isQualifiedForm(String identifier, String base) {
    if (!identifier.startsWith(idPrefix)) return false;
    final dot = identifier.indexOf('.');
    if (dot < 0 || dot == idPrefix.length) return false;
    return identifier.substring(dot + 1) == sanitize(base);
  }
}
