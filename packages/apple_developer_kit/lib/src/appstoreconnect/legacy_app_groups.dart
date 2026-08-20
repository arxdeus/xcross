/// App Groups over Apple's pre-JSON `QH65B2` protocol.
///
/// App Groups are the one provisioning resource that has no modern
/// representation at all: Apple's own App Store Connect OpenAPI specification
/// declares 966 paths and not one of them mentions App Groups, and
/// developerservices2's JSON:API surface answers
/// `403 The API key in use does not allow this request` to any capability
/// change. The only surface that can create a group and attach it to an App ID
/// is the pre-JSON plist protocol Xcode itself speaks.
///
/// That protocol authenticates two ways, and this class deliberately knows
/// about neither: callers hand it a header provider. A GrandSlam (Apple ID)
/// session supplies `X-Apple-GS-Token` plus Anisette headers, while an App
/// Store Connect API key supplies an ordinary `Authorization: Bearer <JWT>` —
/// the same host validates both, answering an unknown key with the identical
/// "properly configured and signed" text `api.appstoreconnect.apple.com`
/// returns.
///
/// Without this, an app and its share extension are each sandboxed into their
/// own container and cannot exchange the data an extension exists to hand
/// over.
library;

import 'package:apple_developer_kit/src/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_models.dart';
import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/anisette_state.dart';
import 'package:apple_developer_kit/src/grandslam/internal/grandslam_response_decoder.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:propertylistserialization/propertylistserialization.dart';

/// Supplies the auth (and, for GrandSlam, Anisette) headers for one request.
typedef LegacyAuthHeaders = Future<Map<String, String>> Function();

/// Resolves the team the request acts on. An Apple ID session carries it
/// directly; an API key has to look it up (see `AscClient`).
typedef LegacyTeamId = Future<String> Function();

/// The `QH65B2` App Groups actions, shared by both provisioning backends.
@internal
final class LegacyAppGroups {
  const LegacyAppGroups({
    required http.Client httpClient,
    required LegacyAuthHeaders authHeaders,
    required LegacyTeamId teamId,
  }) : _http = httpClient,
       _authHeaders = authHeaders,
       _teamId = teamId;

  static const _baseUrl = 'https://developerservices2.apple.com/services/QH65B2';
  static const _clientId = 'XABBG36SBA';

  /// Apple's internal feature key for the App Groups capability, as sent by
  /// Xcode to `ios/updateAppId.action`. Cross-checked against AltSign's
  /// `ALTFeatureAppGroups`.
  static const appGroupsFeature = 'APG3427HIY';

  final http.Client _http;
  final LegacyAuthHeaders _authHeaders;
  final LegacyTeamId _teamId;

  /// The App Group on the team whose `identifier` is [identifier], or null.
  ///
  /// The protocol has no filter parameter, so the match happens here.
  Future<AscAppGroup?> find(String identifier) async {
    final response = await _action('ios/listApplicationGroups.action');
    final groups = response['applicationGroupList'];
    if (groups is! List) return null;
    for (final entry in groups) {
      if (entry is! Map) continue;
      if (entry['identifier'] != identifier) continue;
      return _fromLegacy(entry);
    }
    return null;
  }

  /// Registers a new App Group.
  Future<AscAppGroup> register({
    required String identifier,
    required String name,
  }) async {
    final response = await _action('ios/addApplicationGroup.action', {
      'identifier': identifier,
      // Apple rejects punctuation in group names the same way it does in
      // App ID names.
      'name': sanitizeName(name),
    });
    final group = response['applicationGroup'];
    if (group is! Map) {
      throw const AppleError(
        'Developer Services add App Group response is missing the group',
      );
    }
    return _fromLegacy(group);
  }

  /// Turns the App Groups capability on for [appIdResourceId] and links
  /// [appGroupResourceIds] to it.
  ///
  /// Both steps are required: `updateAppId.action` flips the feature flag
  /// that makes Apple issue a `com.apple.security.application-groups`
  /// entitlement at all, while `assignApplicationGroupToAppId.action` decides
  /// which groups end up inside it.
  Future<void> assign({
    required String appIdResourceId,
    required List<String> appGroupResourceIds,
  }) async {
    await _action('ios/updateAppId.action', {
      'appIdId': appIdResourceId,
      appGroupsFeature: true,
    });
    if (appGroupResourceIds.isEmpty) return;
    await _action('ios/assignApplicationGroupToAppId.action', {
      'appIdId': appIdResourceId,
      'applicationGroups': appGroupResourceIds,
    });
  }

  /// Apple's App ID and App Group names accept alphanumerics and spaces only.
  static String sanitizeName(String name) {
    final sanitized = name.replaceAll(RegExp('[^A-Za-z0-9 ]'), ' ').trim();
    return sanitized.isEmpty ? 'xcross group' : sanitized;
  }

  /// A legacy group entry names the resource id `applicationGroup` and the
  /// `group.…` string `identifier`, the opposite way round from JSON:API.
  static AscAppGroup _fromLegacy(Map<dynamic, dynamic> entry) {
    final id = entry['applicationGroup'];
    final identifier = entry['identifier'];
    if (id is! String || identifier is! String) {
      throw const AppleError(
        'Developer Services App Group entry is missing an identifier',
      );
    }
    return AscAppGroup(
      id: id,
      identifier: identifier,
      name: entry['name'] as String? ?? '',
    );
  }

  /// Performs one `QH65B2` action.
  ///
  /// The protocol POSTs an XML plist, always answers HTTP 200 on the
  /// application path, and reports failure through `resultCode` rather than a
  /// status code. Transport-level auth failures do use real status codes.
  Future<Map<String, Object?>> _action(
    String action, [
    Map<String, Object?> parameters = const {},
  ]) async {
    final response = await _http.post(
      Uri.parse('$_baseUrl/$action?clientId=$_clientId'),
      headers: {..._protocolHeaders, ...await _authHeaders()},
      body: PropertyListSerialization.stringWithPropertyList({
        'clientId': _clientId,
        'protocolVersion': 'QH65B2',
        'requestId': AnisetteState.generateUuidV4().toUpperCase(),
        'teamId': await _teamId(),
        ...parameters,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppleApiError(
        response.statusCode,
        'Developer Services $action failed (HTTP ${response.statusCode}): '
        '${_legacyMessage(response.body) ?? response.body}',
      );
    }
    final plist = GrandSlamResponse.decodePlist(
      response.body,
      context: 'Developer Services $action response',
    );
    rejectFailure(plist, action: action);
    return plist;
  }

  static const _protocolHeaders = {
    'Accept': 'text/x-xml-plist',
    'Content-Type': 'text/x-xml-plist',
    'Accept-Language': 'en-us',
    'User-Agent': 'Xcode',
    'X-Xcode-Version': '11.2 (11B41)',
    'X-Apple-App-Info': 'com.apple.gs.xcode.auth',
  };

  /// The protocol reports application failures through `resultCode`, and
  /// sends it as an int or a string depending on the error.
  static void rejectFailure(
    Map<String, Object?> plist, {
    required String action,
  }) {
    final resultCode = switch (plist['resultCode']) {
      final int value => value,
      final String value => int.tryParse(value),
      _ => null,
    };
    if (resultCode == null) {
      throw AppleError(
        'Developer Services $action response has an invalid resultCode',
      );
    }
    if (resultCode != 0) {
      final message =
          plist['userString'] ?? plist['resultString'] ?? 'unknown error';
      throw AppleError(
        'Developer Services $action failed ($resultCode): $message',
      );
    }
  }

  /// An auth rejection still comes back as a plist, so pull the human-readable
  /// string out rather than dumping XML at the user.
  static String? _legacyMessage(String body) {
    try {
      final plist =
          PropertyListSerialization.propertyListWithString(body) as Map;
      final message = plist['userString'] ?? plist['resultString'];
      return message is String && message.isNotEmpty ? message : null;
    } on Object {
      return null;
    }
  }
}
