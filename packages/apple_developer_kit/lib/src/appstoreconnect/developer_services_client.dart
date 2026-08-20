import 'dart:convert';
import 'dart:io';

import 'package:apple_developer_kit/src/apple_http_client.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_models.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_payloads.dart';
import 'package:apple_developer_kit/src/appstoreconnect/legacy_app_groups.dart';
import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/anisette_state.dart';
import 'package:apple_developer_kit/src/grandslam/app_token_exchange.dart';
import 'package:apple_developer_kit/src/grandslam/grandslam_session_store.dart';
import 'package:apple_developer_kit/src/grandslam/internal/grandslam_response_decoder.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:propertylistserialization/propertylistserialization.dart';

@immutable
final class DeveloperServicesTeam {
  const DeveloperServicesTeam({
    required this.id,
    required this.name,
    required this.status,
  });

  final String id;
  final String name;
  final String status;
}

/// Provisioning against Apple's legacy `developerservices2` endpoints, which
/// an Apple ID (GrandSlam) session can reach without an App Store Connect
/// API key.
///
/// The resource schema matches App Store Connect, but the transport does
/// not: every call is a POST, `teamId` must be threaded in by hand, and the
/// team listing still speaks XML plist. See [_withMethodOverride] and
/// [listTeams].
final class DeveloperServicesClient implements DevelopmentProvisioningClient {
  DeveloperServicesClient({
    required this.token,
    required this.teamId,
    required Future<Map<String, String>> Function() fetchAnisetteHeaders,
    http.Client? httpClient,
  }) : _fetchAnisetteHeaders = fetchAnisetteHeaders,
       _http = httpClient ?? AppleHttp.createAppleHttpClient();

  factory DeveloperServicesClient.fromSession(
    GrandSlamSession session,
    Future<Map<String, String>> Function() fetchAnisetteHeaders, {
    http.Client? httpClient,
  }) => DeveloperServicesClient(
    token: session.token,
    teamId: session.teamId,
    fetchAnisetteHeaders: fetchAnisetteHeaders,
    httpClient: httpClient,
  );

  static const _baseUrl = 'https://developerservices2.apple.com/services';
  static const _legacyClientId = 'XABBG36SBA';
  static const _appIdentifier = 'com.apple.gs.xcode.auth';
  static const _xcodeVersion = '16.2 (16C5031c)';
  static const _clientInfo =
      '<VirtualMac2,1> <macOS;15.1.1;24B91> '
      '<com.apple.AuthKit/1 (com.apple.dt.Xcode/23505)>';

  final DeveloperServicesLoginToken token;
  final String teamId;
  final Future<Map<String, String>> Function() _fetchAnisetteHeaders;
  final http.Client _http;

  /// Lists the teams [token] can provision for.
  ///
  /// Static because it runs before a team is chosen, i.e. before a
  /// [DeveloperServicesClient] can be constructed. It is also the one call
  /// that still uses the pre-JSON `QH65B2` plist protocol, with its own
  /// header set and its own `resultCode` error convention.
  static Future<List<DeveloperServicesTeam>> listTeams({
    required DeveloperServicesLoginToken token,
    required Future<Map<String, String>> Function() fetchAnisetteHeaders,
    http.Client? httpClient,
  }) async {
    _rejectExpired(token);
    final anisette = await fetchAnisetteHeaders();
    final client = httpClient ?? AppleHttp.createAppleHttpClient();
    try {
      final response = await client.post(
        Uri.parse(
          '$_baseUrl/QH65B2/listTeams.action?clientId=$_legacyClientId',
        ),
        headers: {...anisette, ..._legacyHeaders(token)},
        body: PropertyListSerialization.stringWithPropertyList({
          'requestId': AnisetteState.generateUuidV4(),
          'clientId': _legacyClientId,
          'protocolVersion': 'QH65B2',
          'userLocale': [Platform.localeName],
        }),
      );
      return _parseTeams(response);
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<AscCertificate> createDevelopmentCertificate({
    required String csrPem,
  }) async => AscCertificate.fromJson(
    _data(
      // developerservices2 names the type `DEVELOPMENT`, not App Store
      // Connect's `IOS_DEVELOPMENT`.
      await _post(
        '/v1/certificates',
        AscPayloads.certificate(certificateType: 'DEVELOPMENT', csrPem: csrPem),
      ),
    ),
  );

  @override
  Future<List<String>> listCertificateIds() async =>
      _ids(await _getCollection('/v1/certificates'));

  @override
  Future<List<String>> findCertificateIdsBySerial(String serialNumber) async =>
      _ids(
        await _getCollection(
          '/v1/certificates?filter[serialNumber]='
          '${Uri.encodeQueryComponent(serialNumber)}',
        ),
      );

  @override
  Future<void> revokeCertificate(String certificateId) async {
    await _withMethodOverride('/v1/certificates/$certificateId', 'DELETE');
  }

  @override
  Future<List<AscDevice>> listDevices() async => [
    for (final entry in await _getCollection('/v1/devices'))
      AscDevice.fromJson((entry! as Map).cast<String, dynamic>()),
  ];

  @override
  Future<AscDevice> registerDevice({
    required String udid,
    required String name,
  }) async {
    try {
      return AscDevice.fromJson(
        _data(
          await _post(
            '/v1/devices',
            AscPayloads.device(udid: udid, name: name),
          ),
        ),
      );
    } on AppleApiError catch (error) {
      // 409 means the UDID is already on the team; re-registering is not
      // possible, so adopt the existing resource instead of failing.
      if (error.statusCode != 409) rethrow;
      final existing = await findDeviceByUdid(udid);
      if (existing != null) return existing;
      rethrow;
    }
  }

  /// developerservices2 ignores `filter[udid]`, so the match happens here.
  @override
  Future<AscDevice?> findDeviceByUdid(String udid) async {
    for (final device in await listDevices()) {
      if (device.udid == udid) return device;
    }
    return null;
  }

  /// developerservices2 treats `filter[identifier]` as a prefix match, so the
  /// exact identifier has to be picked out of the page.
  @override
  Future<AscBundleId?> findBundleId(String identifier) async {
    final page = await _getCollection(
      '/v1/bundleIds?filter[identifier]='
      '${Uri.encodeQueryComponent(identifier)}',
    );
    for (final entry in page) {
      final bundleId = AscBundleId.fromJson(
        (entry! as Map).cast<String, dynamic>(),
      );
      if (bundleId.identifier == identifier) return bundleId;
    }
    return null;
  }

  @override
  Future<AscBundleId> registerBundleId({
    required String identifier,
    required String name,
  }) async => AscBundleId.fromJson(
    _data(
      await _post(
        '/v1/bundleIds',
        AscPayloads.bundleId(identifier: identifier, name: name),
      ),
    ),
  );

  /// App Groups live only on the pre-JSON `QH65B2` plist protocol, which
  /// this session authenticates with its GrandSlam token plus Anisette
  /// headers. See [LegacyAppGroups] for why no modern surface can do it.
  @override
  Future<AscAppGroup?> findAppGroup(String identifier) =>
      _appGroups.find(identifier);

  @override
  Future<AscAppGroup> registerAppGroup({
    required String identifier,
    required String name,
  }) => _appGroups.register(identifier: identifier, name: name);

  @override
  Future<void> assignAppGroups({
    required String bundleIdResourceId,
    required List<String> appGroupResourceIds,
  }) => _appGroups.assign(
    appIdResourceId: bundleIdResourceId,
    appGroupResourceIds: appGroupResourceIds,
  );

  late final LegacyAppGroups _appGroups = LegacyAppGroups(
    httpClient: _http,
    authHeaders: () async => {
      ..._legacyHeaders(token),
      ...await _fetchAnisetteHeaders(),
    },
    teamId: () => Future.value(teamId),
  );

  @override
  Future<List<String>> listProfileIdsForBundle(
    String bundleIdResourceId,
  ) async =>
      _ids(await _getCollection('/v1/bundleIds/$bundleIdResourceId/profiles'));

  @override
  Future<void> deleteProfile(String profileId) async {
    await _withMethodOverride('/v1/profiles/$profileId', 'DELETE');
  }

  @override
  Future<AscProfile> createProfile({
    required String name,
    required String bundleIdResourceId,
    required List<String> certificateResourceIds,
    required List<String> deviceResourceIds,
  }) async => AscProfile.fromJson(
    _data(
      await _post(
        '/v1/profiles',
        AscPayloads.profile(
          name: name,
          bundleIdResourceId: bundleIdResourceId,
          certificateResourceIds: certificateResourceIds,
          deviceResourceIds: deviceResourceIds,
        ),
      ),
    ),
  );

  /// Performs a non-mutating, one-item request so callers can validate the
  /// saved token/team/Anisette state before choosing this provider.
  Future<void> verifyAccess() async {
    await _get('/v1/devices?limit=1');
  }

  @override
  void close() => _http.close();

  Future<Map<String, dynamic>> _get(String path) =>
      _withMethodOverride(path, 'GET');

  /// developerservices2 only accepts POST; other verbs ride along in
  /// `X-HTTP-Method-Override`, with the query string moved into the body.
  Future<Map<String, dynamic>> _withMethodOverride(
    String path,
    String method,
  ) async {
    _rejectExpired(token);
    final logicalUrl = '$_baseUrl$path';
    final response = await _http.post(
      Uri.parse(logicalUrl.split('?').first),
      headers: {
        ..._headers(token),
        ...await _fetchAnisetteHeaders(),
        'X-HTTP-Method-Override': method,
      },
      body: jsonEncode({
        'urlEncodedQueryParams': Uri(
          queryParameters: {
            ...Uri.parse(logicalUrl).queryParameters,
            'teamId': teamId,
          },
        ).query,
      }),
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    _rejectExpired(token);
    final response = await _http.post(
      Uri.parse('$_baseUrl$path'),
      headers: {..._headers(token), ...await _fetchAnisetteHeaders()},
      body: jsonEncode(_withTeamId(body)),
    );
    return _decode(response);
  }

  /// developerservices2 requires `teamId` inside `data.attributes`; App Store
  /// Connect infers it from the API key.
  Map<String, dynamic> _withTeamId(Map<String, dynamic> body) {
    final data = (body['data'] as Map).cast<String, dynamic>();
    // A relationship-only payload (e.g. attaching capabilities to a bundle
    // id) carries no attributes of its own; teamId still has to go somewhere.
    final rawAttributes = data['attributes'];
    final attributes = rawAttributes is Map
        ? rawAttributes.cast<String, dynamic>()
        : <String, dynamic>{};
    return {
      ...body,
      'data': {
        ...data,
        'attributes': {...attributes, 'teamId': teamId},
      },
    };
  }

  /// Reads every page of a `data` collection, following `links.next`.
  Future<List<Object?>> _getCollection(String path) async {
    final values = <Object?>[];
    final seenNextLinks = <String>{};
    var nextPath = path;
    while (true) {
      final json = await _get(nextPath);
      final data = json['data'];
      if (data is! List) {
        throw const AppleError(
          'Developer Services collection response has no data',
        );
      }
      values.addAll(data);

      final links = json['links'];
      final next = links is Map ? links['next'] : null;
      if (next is! String || next.isEmpty) return values;
      // A next link that repeats one we already followed would loop forever.
      if (!seenNextLinks.add(next)) {
        throw const AppleError(
          'Developer Services returned a repeated next link',
        );
      }
      nextPath = _nextPagePath(path, next);
    }
  }

  /// Rebuilds [originalPath] with the cursor from [nextLink]: the returned
  /// link points at the bare endpoint and would otherwise drop the filters.
  static String _nextPagePath(String originalPath, String nextLink) {
    final next = Uri.parse(nextLink);
    final cursor = next.queryParameters['cursor'];
    final limit = next.queryParameters['limit'];
    if (cursor == null || limit == null) {
      throw const AppleError(
        'Developer Services returned an invalid next link',
      );
    }
    final original = Uri.parse(originalPath);
    return Uri(
      path: original.path,
      queryParameters: {
        ...original.queryParameters,
        'cursor': cursor,
        'limit': limit,
      },
    ).toString();
  }

  static Map<String, String> _headers(DeveloperServicesLoginToken token) => {
    'Accept': 'application/vnd.api+json',
    'Content-Type': 'application/vnd.api+json',
    'Accept-Language': 'en-US,en;q=0.9',
    'Accept-Encoding': 'gzip, deflate',
    'User-Agent': 'Xcode',
    'X-Xcode-Version': _xcodeVersion,
    'X-MMe-Client-Info': _clientInfo,
    'X-Apple-App-Info': _appIdentifier,
    'X-Apple-I-Identity-Id': token.adsid,
    'X-Apple-GS-Token': token.token,
  };

  /// Header set for the legacy `listTeams.action` protocol, which still pins
  /// an older Xcode version and negotiates XML plist rather than JSON:API.
  static Map<String, String> _legacyHeaders(
    DeveloperServicesLoginToken token,
  ) => {
    'Accept': 'text/x-xml-plist',
    'Content-Type': 'text/x-xml-plist',
    'User-Agent': 'Xcode',
    'X-Xcode-Version': '14.2 (14C18)',
    'X-Apple-App-Info': _appIdentifier,
    'X-Apple-I-Identity-Id': token.adsid,
    'X-Apple-GS-Token': token.token,
  };

  static void _rejectExpired(DeveloperServicesLoginToken token) {
    if (token.isExpired) {
      throw const AppleError(
        'Developer Services session has expired. Run xcross auth again.',
      );
    }
  }

  static List<DeveloperServicesTeam> _parseTeams(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppleError(
        'Developer Services list teams failed '
        '(HTTP ${response.statusCode})',
      );
    }
    final plist = GrandSlamResponse.decodePlist(
      response.body,
      context: 'Developer Services list teams response',
    );
    LegacyAppGroups.rejectFailure(plist, action: 'list teams');

    final teams = plist['teams'];
    if (teams is! List) {
      throw const AppleError(
        'Developer Services list teams response is missing teams',
      );
    }
    return [
      for (final team in teams)
        if (team is Map)
          DeveloperServicesTeam(
            id: _requiredString(team, 'teamId'),
            name: _requiredString(team, 'name'),
            status: _requiredString(team, 'status'),
          ),
    ];
  }

  static Map<String, dynamic> _decode(http.Response response) {
    final Object? decoded = response.body.isEmpty
        ? null
        : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppleApiError(
        response.statusCode,
        'Developer Services API error (HTTP ${response.statusCode}): '
        '${_errorDetails(decoded) ?? response.body}',
      );
    }
    // A successful revoke answers with no body.
    if (decoded == null) return const {};
    return (decoded as Map).cast<String, dynamic>();
  }

  static String? _errorDetails(Object? decoded) {
    if (decoded is! Map || decoded['errors'] is! List) return null;
    final details = <String>[
      for (final error in decoded['errors'] as List)
        if (error is Map && (error['detail'] ?? error['title']) != null)
          (error['detail'] ?? error['title']).toString(),
    ];
    return details.isEmpty ? null : details.join('; ');
  }

  static Map<String, dynamic> _data(Map<String, dynamic> json) =>
      (json['data'] as Map).cast<String, dynamic>();

  static List<String> _ids(List<Object?> collection) => [
    for (final entry in collection) (entry! as Map)['id'] as String,
  ];

  static String _requiredString(Map<dynamic, dynamic> map, String key) {
    final value = map[key];
    if (value is! String || value.isEmpty) {
      throw AppleError(
        'Developer Services list teams response has an invalid $key',
      );
    }
    return value;
  }
}
