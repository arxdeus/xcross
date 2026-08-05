/// Apple's GrandSlam ("GsService2") endpoint bag and the lookup call that
/// fetches it.
///
/// The lookup is a `GET` with no body, and its response is a bare dict
/// keyed by `urls` - no `Status`/`Response` envelope, unlike the
/// provisioning POSTs. Verified against both Dadoum/Provision's
/// `ProvisioningSession.loadURLBag` and xtool's `GrandSlamLookupManager`.
library;

import 'package:apple_developer_kit/src/errors.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:propertylistserialization/propertylistserialization.dart';

final Uri _lookupUrl = Uri.parse(
  'https://gsa.apple.com/grandslam/GsService2/lookup',
);

/// The `urls` dict returned by the GrandSlam lookup endpoint.
///
/// Only [midStartProvisioning]/[midFinishProvisioning] drive the one-time
/// device provisioning handshake; the rest are modeled so the sign-in and
/// two-factor layers do not have to repeat the lookup.
@immutable
class GrandSlamEndpoints {
  const GrandSlamEndpoints({
    required this.gsService,
    required this.secondaryAuth,
    required this.trustedDeviceSecondaryAuth,
    required this.validateCode,
    required this.midStartProvisioning,
    required this.midFinishProvisioning,
  });

  /// Parses the value of the lookup response's top-level `urls` key.
  factory GrandSlamEndpoints.fromPlistUrls(Map<Object?, Object?> urls) {
    String field(String key) {
      final value = urls[key];
      if (value is! String) {
        throw AppleError(
          'GrandSlam endpoint lookup response missing "$key" (or not a string)',
        );
      }
      return validateGrandSlamUrl(value, field: key).toString();
    }

    return GrandSlamEndpoints(
      gsService: field('gsService'),
      secondaryAuth: field('secondaryAuth'),
      trustedDeviceSecondaryAuth: field('trustedDeviceSecondaryAuth'),
      validateCode: field('validateCode'),
      midStartProvisioning: field('midStartProvisioning'),
      midFinishProvisioning: field('midFinishProvisioning'),
    );
  }

  final String gsService;
  final String secondaryAuth;
  final String trustedDeviceSecondaryAuth;
  final String validateCode;
  final String midStartProvisioning;
  final String midFinishProvisioning;

  /// Rejects anything that is not a plain HTTPS URL on an Apple host, so a
  /// tampered endpoint bag cannot redirect credentials elsewhere.
  @useResult
  static Uri validateGrandSlamUrl(String value, {required String field}) {
    final uri = Uri.tryParse(value);
    final host = uri?.host.toLowerCase() ?? '';
    final isAppleHost = host == 'apple.com' || host.endsWith('.apple.com');
    if (uri == null ||
        uri.scheme != 'https' ||
        !isAppleHost ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443)) {
      throw AppleError(
        'GrandSlam endpoint "$field" is not a trusted Apple HTTPS URL.',
      );
    }
    return uri;
  }

  /// Sends a GrandSlam request with redirects disabled - a 3xx on these
  /// endpoints would mean credentials leaving Apple's hosts.
  static Future<http.Response> sendGrandSlamRequest(
    http.Client client, {
    required String method,
    required String url,
    required String operation,
    Map<String, String>? headers,
    String? body,
  }) async {
    final request = http.Request(
      method,
      validateGrandSlamUrl(url, field: operation),
    )..followRedirects = false;
    if (headers != null) request.headers.addAll(headers);
    if (body != null) request.body = body;

    final response = await http.Response.fromStream(await client.send(request));
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw AppleError('GrandSlam $operation refused an HTTP redirect.');
    }
    return response;
  }

  /// Fetches the endpoint bag. No Anisette data exists yet at this point;
  /// [headers] carries the persisted pseudo-identity and locale headers
  /// (see `AnisetteHeaders.buildAnisetteLookupHeaders`).
  ///
  /// Callers cache the result in memory for the process lifetime.
  static Future<GrandSlamEndpoints> fetchGrandSlamEndpoints(
    http.Client client, {
    required Map<String, String> headers,
  }) async {
    final response = await sendGrandSlamRequest(
      client,
      method: 'GET',
      url: _lookupUrl.toString(),
      operation: 'endpoint lookup',
      headers: headers,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppleError(
        'GrandSlam endpoint lookup failed (HTTP ${response.statusCode})',
      );
    }

    final Object decoded;
    try {
      decoded = PropertyListSerialization.propertyListWithString(response.body);
    } on PropertyListException catch (e) {
      throw AppleError(
        'GrandSlam endpoint lookup response was not a plist: $e',
      );
    }
    return switch (decoded) {
      {'urls': final Map<Object?, Object?> urls} =>
        GrandSlamEndpoints.fromPlistUrls(urls),
      Map<Object?, Object?>() => throw const AppleError(
        'GrandSlam endpoint lookup response missing "urls"',
      ),
      _ => throw const AppleError(
        'GrandSlam endpoint lookup response was not a plist dictionary',
      ),
    };
  }
}
