import 'dart:convert';

import 'package:apple_developer_kit/src/apple_http_client.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_config.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_jwt.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_models.dart';
import 'package:apple_developer_kit/src/errors.dart';
import 'package:http/http.dart' as http;

/// An Apple provisioning API error, carrying the HTTP status so callers can
/// branch on codes like 409 without caring which backend produced it.
class AppleApiError extends AppleError {
  AppleApiError(this.statusCode, String message) : super(message);

  final int statusCode;
}

abstract class DevelopmentProvisioningClient {
  Future<AscCertificate> createDevelopmentCertificate({required String csrPem});

  /// Resource ids of every certificate currently on the team (xtool lists
  /// the unfiltered collection before deciding what to revoke).
  Future<List<String>> listCertificateIds();

  /// Resource ids of certificates whose `serialNumber` attribute equals
  /// [serialNumber]. Used to resolve the team-side id before attaching a
  /// cert to a profile (xtool never uses the create-response id alone).
  Future<List<String>> findCertificateIdsBySerial(String serialNumber);

  Future<void> revokeCertificate(String certificateId);

  Future<List<AscDevice>> listDevices();

  Future<AscDevice> registerDevice({
    required String udid,
    required String name,
  });

  Future<AscDevice?> findDeviceByUdid(String udid);

  Future<AscBundleId?> findBundleId(String identifier);

  Future<AscBundleId> registerBundleId({
    required String identifier,
    required String name,
  });

  /// Profile resource ids currently linked to [bundleIdResourceId].
  Future<List<String>> listProfileIdsForBundle(String bundleIdResourceId);

  Future<void> deleteProfile(String profileId);

  Future<AscProfile> createProfile({
    required String name,
    required String bundleIdResourceId,
    required List<String> certificateResourceIds,
    required List<String> deviceResourceIds,
  });

  void close();
}

/// Thin client for the subset of the App Store Connect API needed to
/// provision iOS Development signing (certificates, devices, bundle ids,
/// profiles) using only a Team-scoped API key - no interactive Apple ID
/// login.
class AscClient implements DevelopmentProvisioningClient {
  AscClient(this.credentials, {http.Client? httpClient})
    : _http = httpClient ?? createAppleHttpClient();

  final AscCredentials credentials;
  final http.Client _http;

  static const _baseUrl = 'https://api.appstoreconnect.apple.com/v1';

  /// Creates a new Development signing certificate from [csrPem].
  Future<AscCertificate> createCertificate({
    required String certificateType,
    required String csrPem,
  }) async {
    final json = await _post('/certificates', {
      'data': {
        'type': 'certificates',
        'attributes': {
          'certificateType': certificateType,
          'csrContent': csrPem,
        },
      },
    });
    return AscCertificate.fromJson((json['data'] as Map).cast());
  }

  @override
  Future<AscCertificate> createDevelopmentCertificate({
    required String csrPem,
  }) => createCertificate(certificateType: 'IOS_DEVELOPMENT', csrPem: csrPem);

  @override
  Future<List<String>> listCertificateIds() async {
    final json = await _get('/certificates');
    return [for (final e in json['data'] as List) (e as Map)['id'] as String];
  }

  @override
  Future<List<String>> findCertificateIdsBySerial(String serialNumber) async {
    final json = await _get(
      '/certificates?filter[serialNumber]=${Uri.encodeQueryComponent(serialNumber)}',
    );
    return [for (final e in json['data'] as List) (e as Map)['id'] as String];
  }

  @override
  Future<void> revokeCertificate(String certificateId) async {
    _decode(
      await _http.delete(
        Uri.parse('$_baseUrl/certificates/$certificateId'),
        headers: await _headers(),
      ),
    );
  }

  /// Lists all devices registered on the team.
  @override
  Future<List<AscDevice>> listDevices() async {
    final json = await _get('/devices');
    return (json['data'] as List)
        .map((e) => AscDevice.fromJson((e as Map).cast()))
        .toList();
  }

  /// Registers a new device by UDID.
  @override
  Future<AscDevice> registerDevice({
    required String udid,
    required String name,
  }) async {
    final json = await _post('/devices', {
      'data': {
        'type': 'devices',
        'attributes': {'name': name, 'platform': 'IOS', 'udid': udid},
      },
    });
    return AscDevice.fromJson((json['data'] as Map).cast());
  }

  /// Finds an already-registered device by UDID, or null if not found.
  ///
  /// Apple limits device registrations per membership year - always check
  /// with this before [registerDevice] instead of blindly re-registering.
  @override
  Future<AscDevice?> findDeviceByUdid(String udid) async {
    final json = await _get(
      '/devices?filter[udid]=${Uri.encodeQueryComponent(udid)}',
    );
    final data = json['data'] as List;
    if (data.isEmpty) return null;
    return AscDevice.fromJson((data.first as Map).cast());
  }

  /// Finds an already-registered bundle id, or null if not found.
  @override
  Future<AscBundleId?> findBundleId(String identifier) async {
    final json = await _get(
      '/bundleIds?filter[identifier]=${Uri.encodeQueryComponent(identifier)}',
    );
    final data = json['data'] as List;
    if (data.isEmpty) return null;
    return AscBundleId.fromJson((data.first as Map).cast());
  }

  /// Registers a new bundle id.
  @override
  Future<AscBundleId> registerBundleId({
    required String identifier,
    required String name,
  }) async {
    final json = await _post('/bundleIds', {
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
  Future<List<String>> listProfileIdsForBundle(
    String bundleIdResourceId,
  ) async {
    final json = await _get('/bundleIds/$bundleIdResourceId/profiles');
    return [for (final e in json['data'] as List) (e as Map)['id'] as String];
  }

  @override
  Future<void> deleteProfile(String profileId) async {
    _decode(
      await _http.delete(
        Uri.parse('$_baseUrl/profiles/$profileId'),
        headers: await _headers(),
      ),
    );
  }

  /// Creates a new `IOS_APP_DEVELOPMENT` provisioning profile linking
  /// [bundleIdResourceId], [certificateResourceIds], and
  /// [deviceResourceIds] (all App Store Connect resource ids, not the
  /// human-readable identifiers/UDIDs).
  @override
  Future<AscProfile> createProfile({
    required String name,
    required String bundleIdResourceId,
    required List<String> certificateResourceIds,
    required List<String> deviceResourceIds,
  }) async {
    final json = await _post('/profiles', {
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

  /// Releases the underlying HTTP client's resources.
  @override
  void close() => _http.close();

  Future<Map<String, String>> _headers() async => {
    'Authorization': 'Bearer ${await AscJwt.generate(credentials)}',
    'Content-Type': 'application/json',
  };

  Future<Map<String, dynamic>> _get(String path) async => _decode(
    await _http.get(Uri.parse('$_baseUrl$path'), headers: await _headers()),
  );

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async => _decode(
    await _http.post(
      Uri.parse('$_baseUrl$path'),
      headers: await _headers(),
      body: jsonEncode(body),
    ),
  );

  /// Decodes a JSON:API response, throwing [AppleApiError] (surfacing the
  /// `errors[].detail` App Store Connect sends) on any non-2xx status.
  Map<String, dynamic> _decode(http.Response response) {
    final Object? decoded = response.body.isEmpty
        ? null
        : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppleApiError(
        response.statusCode,
        'App Store Connect API error '
        '(HTTP ${response.statusCode}): ${_firstErrorDetail(decoded) ?? response.body}',
      );
    }
    // A successful DELETE answers 204 with no body.
    if (decoded == null) return const {};
    return (decoded as Map).cast<String, dynamic>();
  }

  static String? _firstErrorDetail(Object? decoded) {
    if (decoded is! Map) return null;
    final errors = decoded['errors'];
    if (errors is! List || errors.isEmpty) return null;
    final first = errors.first;
    if (first is! Map) return null;
    return (first['detail'] ?? first['title'])?.toString();
  }
}
