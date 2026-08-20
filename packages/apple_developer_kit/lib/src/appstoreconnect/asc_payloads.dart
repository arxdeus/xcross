/// JSON:API request bodies shared by `AscClient` and
/// `DeveloperServicesClient`.
///
/// Both backends accept the same resource schema; only the endpoint host,
/// the auth headers, and the certificate type differ. Keeping the bodies in
/// one place means a payload tweak can't drift between the two clients.
library;

import 'package:meta/meta.dart';

@internal
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

  static Map<String, dynamic> appGroup({
    required String identifier,
    required String name,
  }) => {
    'data': {
      'type': 'appGroups',
      'attributes': {'identifier': identifier, 'name': name},
    },
  };

  /// Turns on the App Groups capability for a bundle id and links the groups.
  ///
  /// Posted to `/bundleIds/<id>/bundleIdCapabilities`: the capability is a
  /// sub-resource of the bundle id, not an inline relationship on it. Without
  /// it the groups never reach the issued profile's entitlements, and the app
  /// and its extensions stay in separate containers.
  static Map<String, dynamic> appGroupsCapability({
    required String bundleIdResourceId,
    required List<String> appGroupResourceIds,
  }) => {
    'data': {
      'type': 'bundleIdCapabilities',
      'attributes': {
        'capabilityType': 'APP_GROUPS',
        'settings': [
          {
            'key': 'APP_GROUP_IDENTIFIERS',
            'options': [
              for (final id in appGroupResourceIds) {'key': id},
            ],
          },
        ],
      },
      'relationships': {
        'bundleId': {
          'data': {'type': 'bundleIds', 'id': bundleIdResourceId},
        },
      },
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

  /// Turns a capability on for a bundle id without configuring it.
  ///
  /// Used for `APP_GROUPS` on the App Store Connect key path, where the
  /// groups themselves cannot be enumerated (`/appGroups` does not exist) and
  /// so cannot be linked. Enabling the capability is still what makes Apple
  /// issue profiles carrying `com.apple.security.application-groups`.
  static Map<String, dynamic> enableCapability({
    required String bundleIdResourceId,
    required String capabilityType,
  }) => {
    'data': {
      'type': 'bundleIdCapabilities',
      'attributes': {'capabilityType': capabilityType},
      'relationships': {
        'bundleId': {
          'data': {'type': 'bundleIds', 'id': bundleIdResourceId},
        },
      },
    },
  };
}
