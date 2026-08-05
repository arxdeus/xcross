/// JSON:API request bodies shared by `AscClient` and
/// `DeveloperServicesClient`.
///
/// Both backends accept the same resource schema; only the endpoint host,
/// the auth headers, and the certificate type differ. Keeping the bodies in
/// one place means a payload tweak can't drift between the two clients.
library;

abstract final class AscPayloads {
  static Map<String, dynamic> certificate({
    required String certificateType,
    required String csrPem,
  }) => {
    'data': {
      'type': 'certificates',
      'attributes': {'certificateType': certificateType, 'csrContent': csrPem},
    },
  };

  static Map<String, dynamic> device({
    required String udid,
    required String name,
  }) => {
    'data': {
      'type': 'devices',
      'attributes': {'name': name, 'platform': 'IOS', 'udid': udid},
    },
  };

  static Map<String, dynamic> bundleId({
    required String identifier,
    required String name,
  }) => {
    'data': {
      'type': 'bundleIds',
      'attributes': {'identifier': identifier, 'name': name, 'platform': 'IOS'},
    },
  };

  static Map<String, dynamic> profile({
    required String name,
    required String bundleIdResourceId,
    required List<String> certificateResourceIds,
    required List<String> deviceResourceIds,
  }) => {
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
  };
}
