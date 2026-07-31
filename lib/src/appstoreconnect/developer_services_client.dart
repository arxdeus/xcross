import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/appstoreconnect/asc_client.dart';
import 'package:xcross/src/appstoreconnect/asc_models.dart';
import 'package:xcross/src/grandslam/anisette/anisette_state.dart';
import 'package:xcross/src/grandslam/app_token_exchange.dart';
import 'package:xcross/src/grandslam/grandslam_response.dart';
import 'package:xcross/src/grandslam/grandslam_session_store.dart';
import 'package:xcross/src/util/errors.dart';

class DeveloperServicesTeam {
  const DeveloperServicesTeam({
    required this.id,
    required this.name,
    required this.status,
  });

  final String id;
  final String name;
  final String status;
}

class DeveloperServicesApiError extends XcrossError {
  DeveloperServicesApiError(this.statusCode, String message) : super(message);

  final int statusCode;
}

class DeveloperServicesClient implements DevelopmentProvisioningClient {
  DeveloperServicesClient({
    required this.token,
    required this.teamId,
    required Future<Map<String, String>> Function() fetchAnisetteHeaders,
    http.Client? httpClient,
  }) : _fetchAnisetteHeaders = fetchAnisetteHeaders,
       _http = httpClient ?? http.Client();

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
  static const _appIdentifier = 'com.apple.gs.xcode.auth';
  static const _xcodeVersion = '16.2 (16C5031c)';
  static const _clientInfo =
      '<VirtualMac2,1> <macOS;15.1.1;24B91> '
      '<com.apple.AuthKit/1 (com.apple.dt.Xcode/23505)>';

  final DeveloperServicesLoginToken token;
  final String teamId;
  final Future<Map<String, String>> Function() _fetchAnisetteHeaders;
  final http.Client _http;

  static Future<List<DeveloperServicesTeam>> listTeams({
    required DeveloperServicesLoginToken token,
    required Future<Map<String, String>> Function() fetchAnisetteHeaders,
    http.Client? httpClient,
  }) async {
    _rejectExpired(token);
    final anisette = await fetchAnisetteHeaders();
    final client = httpClient ?? http.Client();
    try {
      final response = await client.post(
        Uri.parse('$_baseUrl/QH65B2/listTeams.action?clientId=XABBG36SBA'),
        headers: {
          ...anisette,
          'Accept': 'text/x-xml-plist',
          'Content-Type': 'text/x-xml-plist',
          'User-Agent': 'Xcode',
          'X-Xcode-Version': '14.2 (14C18)',
          'X-Apple-App-Info': _appIdentifier,
          'X-Apple-I-Identity-Id': token.adsid,
          'X-Apple-GS-Token': token.token,
        },
        body: PropertyListSerialization.stringWithPropertyList({
          'requestId': generateUuidV4(),
          'clientId': 'XABBG36SBA',
          'protocolVersion': 'QH65B2',
          'userLocale': [Platform.localeName],
        }),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw XcrossError(
          'Developer Services list teams failed '
          '(HTTP ${response.statusCode})',
        );
      }
      final plist = decodePlist(
        response.body,
        context: 'Developer Services list teams response',
      );
      final resultCodeValue = plist['resultCode'];
      final resultCode = switch (resultCodeValue) {
        final int value => value,
        final String value => int.tryParse(value),
        _ => null,
      };
      if (resultCode == null) {
        throw XcrossError(
          'Developer Services list teams response has an invalid resultCode',
        );
      }
      if (resultCode != 0) {
        final message =
            plist['userString'] ?? plist['resultString'] ?? 'unknown error';
        throw XcrossError(
          'Developer Services list teams failed ($resultCode): $message',
        );
      }
      final teams = plist['teams'];
      if (teams is! List) {
        throw XcrossError(
          'Developer Services list teams response is missing teams',
        );
      }
      return [
        for (final value in teams)
          if (value is Map)
            DeveloperServicesTeam(
              id: _requiredString(value, 'teamId'),
              name: _requiredString(value, 'name'),
              status: _requiredString(value, 'status'),
            ),
      ];
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<AscCertificate> createDevelopmentCertificate({
    required String csrPem,
  }) async {
    final json = await _post('/v1/certificates', {
      'data': {
        'type': 'certificates',
        'attributes': {'certificateType': 'DEVELOPMENT', 'csrContent': csrPem},
      },
    });
    return AscCertificate.fromJson((json['data'] as Map).cast());
  }

  @override
  Future<List<AscDevice>> listDevices() async => [
    for (final value in await _getCollection('/v1/devices'))
      AscDevice.fromJson((value! as Map).cast()),
  ];

  @override
  Future<AscDevice> registerDevice({
    required String udid,
    required String name,
  }) async {
    try {
      final json = await _post('/v1/devices', {
        'data': {
          'type': 'devices',
          'attributes': {'name': name, 'platform': 'IOS', 'udid': udid},
        },
      });
      return AscDevice.fromJson((json['data'] as Map).cast());
    } on DeveloperServicesApiError catch (error) {
      if (error.statusCode != 409) rethrow;
      final existing = await findDeviceByUdid(udid);
      if (existing != null) return existing;
      rethrow;
    }
  }

  @override
  Future<AscDevice?> findDeviceByUdid(String udid) async {
    for (final device in await listDevices()) {
      if (device.udid == udid) return device;
    }
    return null;
  }

  @override
  Future<AscBundleId?> findBundleId(String identifier) async {
    final data = await _getCollection(
      '/v1/bundleIds?filter[identifier]=${Uri.encodeQueryComponent(identifier)}',
    );
    for (final value in data) {
      final bundleId = AscBundleId.fromJson((value! as Map).cast());
      if (bundleId.identifier == identifier) return bundleId;
    }
    return null;
  }

  @override
  Future<AscBundleId> registerBundleId({
    required String identifier,
    required String name,
  }) async {
    final json = await _post('/v1/bundleIds', {
      'data': {
        'type': 'bundleIds',
        'attributes': {
          'identifier': identifier,
          'name': name,
          'platform': 'IOS',
        },
      },
    });
    return AscBundleId.fromJson((json['data'] as Map).cast());
  }

  @override
  Future<AscProfile> createProfile({
    required String name,
    required String bundleIdResourceId,
    required List<String> certificateResourceIds,
    required List<String> deviceResourceIds,
  }) async {
    final json = await _post('/v1/profiles', {
      'data': {
        'type': 'profiles',
        'attributes': {'name': name, 'profileType': 'IOS_APP_DEVELOPMENT'},
        'relationships': {
          'bundleId': {
            'data': {'type': 'bundleIds', 'id': bundleIdResourceId},
          },
          'certificates': {
            'data': [
              for (final id in certificateResourceIds)
                {'type': 'certificates', 'id': id},
            ],
          },
          'devices': {
            'data': [
              for (final id in deviceResourceIds) {'type': 'devices', 'id': id},
            ],
          },
        },
      },
    });
    return AscProfile.fromJson((json['data'] as Map).cast());
  }

  /// Performs a non-mutating, one-item request so callers can validate the
  /// saved token/team/Anisette state before choosing this provider.
  Future<void> verifyAccess() async {
    await _get('/v1/devices?limit=1');
  }

  @override
  void close() => _http.close();

  Future<Map<String, dynamic>> _get(String path) async {
    _rejectExpired(token);
    final logicalUrl = Uri.parse('$_baseUrl$path');
    final queryParameters = <String, String>{
      ...logicalUrl.queryParameters,
      'teamId': teamId,
    };
    final response = await _http.post(
      Uri.parse('$_baseUrl${logicalUrl.path.substring('/services'.length)}'),
      headers: {
        ...await _fetchAnisetteHeaders(),
        ..._headers(token),
        'X-HTTP-Method-Override': 'GET',
      },
      body: jsonEncode({
        'urlEncodedQueryParams': Uri(queryParameters: queryParameters).query,
      }),
    );
    return _decode(response);
  }

  Future<List<Object?>> _getCollection(String path) async {
    final values = <Object?>[];
    final seenNextLinks = <String>{};
    var nextPath = path;
    while (true) {
      final json = await _get(nextPath);
      final data = json['data'];
      if (data is! List) {
        throw XcrossError('Developer Services collection response has no data');
      }
      values.addAll(data);

      final links = json['links'];
      final next = links is Map ? links['next'] : null;
      if (next is! String || next.isEmpty) return values;
      if (!seenNextLinks.add(next)) {
        throw XcrossError('Developer Services returned a repeated next link');
      }
      nextPath = _nextPagePath(path, next);
    }
  }

  static String _nextPagePath(String originalPath, String nextLink) {
    final next = Uri.parse(nextLink);
    final cursor = next.queryParameters['cursor'];
    final limit = next.queryParameters['limit'];
    if (cursor == null || limit == null) {
      throw XcrossError('Developer Services returned an invalid next link');
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

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    _rejectExpired(token);
    final data = (body['data'] as Map).cast<String, dynamic>();
    final attributes = (data['attributes'] as Map).cast<String, dynamic>();
    final response = await _http.post(
      Uri.parse('$_baseUrl$path'),
      headers: {...await _fetchAnisetteHeaders(), ..._headers(token)},
      body: jsonEncode({
        ...body,
        'data': {
          ...data,
          'attributes': {...attributes, 'teamId': teamId},
        },
      }),
    );
    return _decode(response);
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

  static void _rejectExpired(DeveloperServicesLoginToken token) {
    if (token.isExpired) {
      throw XcrossError(
        'Developer Services session has expired. Run xcross auth again.',
      );
    }
  }

  static Map<String, dynamic> _decode(http.Response response) {
    final Object? decoded = response.body.isEmpty
        ? null
        : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DeveloperServicesApiError(
        response.statusCode,
        'Developer Services API error (HTTP ${response.statusCode}): '
        '${_errorDetails(decoded) ?? response.body}',
      );
    }
    return (decoded! as Map).cast<String, dynamic>();
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

  static String _requiredString(Map<dynamic, dynamic> map, String key) {
    final value = map[key];
    if (value is! String || value.isEmpty) {
      throw XcrossError(
        'Developer Services list teams response has an invalid $key',
      );
    }
    return value;
  }
}
