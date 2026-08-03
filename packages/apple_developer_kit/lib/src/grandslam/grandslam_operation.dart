/// Shared builder/sender for GrandSlam `o=...` operation requests.
///
/// `o=init`, `o=complete`, and `o=apptokens` all use the same plist
/// envelope and `cpd` (client provisioning data) shape; keeping it here
/// prevents the auth-token layer from drifting away from the SRP layer.
library;

import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/anisette_headers.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/grandslam_endpoints.dart';
import 'package:apple_developer_kit/src/grandslam/grandslam_response.dart';
import 'package:http/http.dart' as http;
import 'package:propertylistserialization/propertylistserialization.dart';

Map<String, Object?> grandSlamClientProvisioningData(
  Map<String, String> anisette, {
  String locale = 'en_US',
}) {
  String requiredHeader(String name) {
    final value = anisette[name];
    if (value == null || value.isEmpty) {
      throw AppleError('Missing required Anisette header "$name"');
    }
    return value;
  }

  final routingInfo = int.tryParse(requiredHeader('X-Apple-I-MD-RINFO'));
  if (routingInfo == null) {
    throw AppleError('Invalid decimal Anisette routing info');
  }

  return {
    'bootstrap': true,
    'icscrec': true,
    'pbe': false,
    'prkgen': true,
    'svct': 'iCloud',
    'loc': locale,
    'X-Apple-I-Client-Time': requiredHeader('X-Apple-I-Client-Time'),
    'X-Apple-I-MD': requiredHeader('X-Apple-I-MD'),
    'X-Apple-I-MD-LU': requiredHeader('X-Apple-I-MD-LU'),
    'X-Apple-I-MD-M': requiredHeader('X-Apple-I-MD-M'),
    'X-Apple-I-MD-RINFO': routingInfo,
    'X-Apple-I-SRL-NO': 'C02LKHBBFD57',
    'X-Apple-I-TimeZone': requiredHeader('X-Apple-I-TimeZone'),
    'X-Apple-Locale': locale,
    'X-Mme-Device-Id': requiredHeader('X-Mme-Device-Id'),
  };
}

String encodeGrandSlamOperationRequest({
  required String operation,
  required String username,
  required Map<String, String> anisette,
  required Map<String, Object?> extraParams,
  String locale = 'en_US',
}) {
  final request = <String, Object?>{
    'o': operation,
    'u': username,
    'cpd': grandSlamClientProvisioningData(anisette, locale: locale),
    ...extraParams,
  };
  return PropertyListSerialization.stringWithPropertyList({
    'Header': {'Version': '1.0.1'},
    'Request': request,
  });
}

Future<Map<String, Object?>> postGrandSlamOperation({
  required http.Client httpClient,
  required String gsService,
  required String operation,
  required String username,
  required Future<Map<String, String>> Function() fetchAnisetteHeaders,
  required Map<String, Object?> extraParams,
  String locale = 'en_US',
}) async {
  final anisette = await fetchAnisetteHeaders();
  final body = encodeGrandSlamOperationRequest(
    operation: operation,
    username: username,
    anisette: anisette,
    extraParams: extraParams,
    locale: locale,
  );

  final response = await sendGrandSlamRequest(
    httpClient,
    method: 'POST',
    url: gsService,
    operation: 'o=$operation',
    headers: {
      'Content-Type': 'text/x-xml-plist',
      'Accept': '*/*',
      'User-Agent': 'akd/1.0 CFNetwork/978.0.7 Darwin/18.7.0',
      'X-MMe-Client-Info': anisette['X-MMe-Client-Info'] ?? anisetteClientInfo,
    },
    body: body,
  );
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw AppleError(
      'GrandSlam o=$operation request failed (HTTP ${response.statusCode})',
    );
  }
  return decodeGrandSlamResponse(response.body);
}
