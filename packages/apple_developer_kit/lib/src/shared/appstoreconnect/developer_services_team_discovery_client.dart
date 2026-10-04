import 'package:apple_developer_kit/src/shared/appstoreconnect/legacy_app_groups.dart';
import 'package:apple_developer_kit/src/shared/errors/errors.dart';
import 'package:apple_developer_kit/src/shared/grandslam/anisette/anisette_state.dart';
import 'package:apple_developer_kit/src/shared/grandslam/app_token_exchange.dart';
import 'package:apple_developer_kit/src/shared/grandslam/internal/grandslam_response_decoder.dart';
import 'package:apple_developer_kit/src/shared/http/apple_http_client.dart';
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

final class DeveloperServicesTeamDiscoveryClient {
  DeveloperServicesTeamDiscoveryClient({
    required http.Client httpClient,
    required Future<Map<String, String>> Function() fetchAnisetteHeaders,
  }) : _http = httpClient,
       _fetchAnisetteHeaders = fetchAnisetteHeaders;

  static const _baseUrl = 'https://developerservices2.apple.com/services';
  static const _legacyClientId = 'XABBG36SBA';
  static const _appIdentifier = 'com.apple.gs.xcode.auth';

  final http.Client _http;
  final Future<Map<String, String>> Function() _fetchAnisetteHeaders;

  Future<List<DeveloperServicesTeam>> listTeams({
    required DeveloperServicesLoginToken token,
    required String localeName,
  }) async {
    _rejectExpired(token);
    final anisette = await _fetchAnisetteHeaders();
    final client = _http;
    final response = await client.post(
      Uri.parse('$_baseUrl/QH65B2/listTeams.action?clientId=$_legacyClientId'),
      headers: {...anisette, ..._legacyHeaders(token)},
      body: PropertyListSerialization.stringWithPropertyList({
        'requestId': AnisetteState.generateUuidV4(),
        'clientId': _legacyClientId,
        'protocolVersion': 'QH65B2',
        'userLocale': [localeName],
      }),
    );
    return _parseTeams(response);
  }

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
    AppleHttp.checkRateLimit(
      response,
      operation: 'Developer Services list teams',
    );
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
