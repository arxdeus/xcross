/// Shared builder/sender for GrandSlam `o=...` operation requests.
///
/// `o=init`, `o=complete`, and `o=apptokens` all use the same plist
/// envelope and `cpd` (client provisioning data) shape; keeping it here
/// prevents the auth-token layer from drifting away from the SRP layer.
library;

import 'package:http/http.dart' as http;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/grandslam/grandslam_response.dart';
import 'package:xcross/src/util/errors.dart';

Map<String, Object?> grandSlamClientProvisioningData(
  Map<String, String> anisette, {
  String locale = 'en_US',
}) => {
  'bootstrap': true,
  'icscrec': true,
  'pbe': false,
  'prkgen': true,
  'svct': 'iCloud',
  'loc': locale,
  ...anisette,
};

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
  final body = encodeGrandSlamOperationRequest(
    operation: operation,
    username: username,
    anisette: await fetchAnisetteHeaders(),
    extraParams: extraParams,
    locale: locale,
  );

  final response = await httpClient.post(
    Uri.parse(gsService),
    headers: const {'Content-Type': 'text/x-xml-plist'},
    body: body,
  );
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw XcrossError(
      'GrandSlam o=$operation request failed (HTTP ${response.statusCode})',
    );
  }
  return decodeGrandSlamResponse(response.body);
}
