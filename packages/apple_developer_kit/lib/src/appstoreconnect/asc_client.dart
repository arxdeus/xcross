import 'dart:convert';

import 'package:apple_developer_kit/src/apple_http_client.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_config.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_jwt.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_models.dart';
import 'package:apple_developer_kit/src/appstoreconnect/asc_payloads.dart';
import 'package:apple_developer_kit/src/errors.dart';
import 'package:http/http.dart' as http;

/// An Apple provisioning API error, carrying the HTTP status so callers can
/// branch on codes like 409 without caring which backend produced it.
class AppleApiError extends AppleError {
  const AppleApiError(this.statusCode, String message) : super(message);

  final int statusCode;
}

/// The provisioning operations xcross needs, shared by the two backends that
/// can supply them: the modern App Store Connect API (`AscClient`, API key)
/// and Apple's legacy developerservices2 endpoints
/// (`DeveloperServicesClient`, Apple ID session).
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
    : _http = httpClient ?? AppleHttp.createAppleHttpClient();

  final AscCredentials credentials;
  final http.Client _http;

  static const _baseUrl = 'https://api.appstoreconnect.apple.com/v1';

  @override
  Future<AscCertificate> createDevelopmentCertificate({
    required String csrPem,
  }) async => AscCertificate.fromJson(
    _data(
      await _post(
        '/certificates',
        AscPayloads.certificate(
          certificateType: 'IOS_DEVELOPMENT',
          csrPem: csrPem,
        ),
      ),
    ),
  );

  @override
  Future<List<String>> listCertificateIds() async =>
      _ids(await _get('/certificates'));

  @override
  Future<List<String>> findCertificateIdsBySerial(String serialNumber) async =>
      _ids(
        await _get(
          '/certificates?filter[serialNumber]='
          '${Uri.encodeQueryComponent(serialNumber)}',
        ),
      );

  @override
  Future<void> revokeCertificate(String certificateId) =>
      _delete('/certificates/$certificateId');

  @override
  Future<List<AscDevice>> listDevices() async => [
    for (final entry in (await _get('/devices'))['data'] as List)
      AscDevice.fromJson((entry as Map).cast<String, dynamic>()),
  ];

  @override
  Future<AscDevice> registerDevice({
    required String udid,
    required String name,
  }) async => AscDevice.fromJson(
    _data(await _post('/devices', AscPayloads.device(udid: udid, name: name))),
  );

  /// Apple limits device registrations per membership year - always check
  /// with this before [registerDevice] instead of blindly re-registering.
  @override
  Future<AscDevice?> findDeviceByUdid(String udid) async => _firstOrNull(
    await _get('/devices?filter[udid]=${Uri.encodeQueryComponent(udid)}'),
    AscDevice.fromJson,
  );

  @override
  Future<AscBundleId?> findBundleId(String identifier) async => _firstOrNull(
    await _get(
      '/bundleIds?filter[identifier]=${Uri.encodeQueryComponent(identifier)}',
    ),
    AscBundleId.fromJson,
  );

  @override
  Future<AscBundleId> registerBundleId({
    required String identifier,
    required String name,
  }) async => AscBundleId.fromJson(
    _data(
      await _post(
        '/bundleIds',
        AscPayloads.bundleId(identifier: identifier, name: name),
      ),
    ),
  );

  @override
  Future<List<String>> listProfileIdsForBundle(
    String bundleIdResourceId,
  ) async => _ids(await _get('/bundleIds/$bundleIdResourceId/profiles'));

  @override
  Future<void> deleteProfile(String profileId) =>
      _delete('/profiles/$profileId');

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
  }) async => AscProfile.fromJson(
    _data(
      await _post(
        '/profiles',
        AscPayloads.profile(
          name: name,
          bundleIdResourceId: bundleIdResourceId,
          certificateResourceIds: certificateResourceIds,
          deviceResourceIds: deviceResourceIds,
        ),
      ),
    ),
  );

  @override
  void close() => _http.close();

  /// A fresh short-lived JWT per request; see [AscJwt].
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

  Future<void> _delete(String path) async {
    _decode(
      await _http.delete(
        Uri.parse('$_baseUrl$path'),
        headers: await _headers(),
      ),
    );
  }

  /// Decodes a JSON:API response, throwing [AppleApiError] (surfacing the
  /// `errors[].detail` App Store Connect sends) on any non-2xx status.
  Map<String, dynamic> _decode(http.Response response) {
    final Object? decoded = response.body.isEmpty
        ? null
        : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppleApiError(
        response.statusCode,
        'App Store Connect API error (HTTP ${response.statusCode}): '
        '${_firstErrorDetail(decoded) ?? response.body}',
      );
    }
    // A successful DELETE answers 204 with no body.
    if (decoded == null) return const {};
    return (decoded as Map).cast<String, dynamic>();
  }

  static String? _firstErrorDetail(Object? decoded) {
    if (decoded case {'errors': [final Map<Object?, Object?> first, ...]}) {
      return (first['detail'] ?? first['title'])?.toString();
    }
    return null;
  }

  static Map<String, dynamic> _data(Map<String, dynamic> json) =>
      (json['data'] as Map).cast<String, dynamic>();

  static List<String> _ids(Map<String, dynamic> json) => [
    for (final entry in json['data'] as List) (entry as Map)['id'] as String,
  ];

  /// Apple answers a `filter[...]` lookup with a collection, so "not found"
  /// is an empty `data` array rather than a 404.
  static T? _firstOrNull<T>(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic> json) fromJson,
  ) {
    final data = json['data'] as List;
    if (data.isEmpty) return null;
    return fromJson((data.first as Map).cast<String, dynamic>());
  }
}
