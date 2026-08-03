/// Apple's GrandSlam ("GsService2") endpoint bag and the lookup call used
/// to fetch it.
///
/// Endpoint set, lookup HTTP method (`GET`, no body), and lookup headers
/// verified against BOTH:
///  - Dadoum/Provision's `ProvisioningSession.loadURLBag`
///    (`lib/provision/adi.d`, D): `request.get(".../GsService2/lookup")`,
///    reading the response's top-level `urls` dict directly (no envelope).
///  - xtool's `GrandSlamLookupManager`/`GrandSlamEndpoints.swift` (Swift):
///    same `urls`-keyed `Response` struct, same field names, and the
///    locale/timezone/country headers modeled below.
/// Both agree GET is correct and that the response is the `urls` dict with
/// no `Status`/`Response` envelope (unlike the provisioning POSTs).
library;

import 'package:apple_developer_kit/src/errors.dart';
import 'package:http/http.dart' as http;
import 'package:propertylistserialization/propertylistserialization.dart';

/// `https://gsa.apple.com/grandslam/GsService2/lookup`'s `urls` dict.
///
/// Only [midStartProvisioning]/[midFinishProvisioning] are consumed by the
/// one-time device provisioning handshake ([AnisetteDataProvider]); the
/// rest are modeled now (all fields the response contains) so later
/// GrandSlam layers (regular sign-in, 2FA) don't need to redo this lookup.
class GrandSlamEndpoints {
  const GrandSlamEndpoints({
    required this.gsService,
    required this.secondaryAuth,
    required this.trustedDeviceSecondaryAuth,
    required this.validateCode,
    required this.midStartProvisioning,
    required this.midFinishProvisioning,
  });

  final String gsService;
  final String secondaryAuth;
  final String trustedDeviceSecondaryAuth;
  final String validateCode;
  final String midStartProvisioning;
  final String midFinishProvisioning;

  /// Parses the plist-decoded `urls` dict (the value of the response's
  /// top-level `"urls"` key) into a [GrandSlamEndpoints].
  factory GrandSlamEndpoints.fromPlistUrls(Map<Object?, Object?> urls) {
    String field(String key) {
      final value = urls[key];
      if (value is! String) {
        throw AppleError(
          'GrandSlam endpoint lookup response missing "$key" (or not a string)',
        );
      }
      return GrandSlamEndpoints.validateGrandSlamUrl(
        value,
        field: key,
      ).toString();
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
      GrandSlamEndpoints.validateGrandSlamUrl(url, field: operation),
    )..followRedirects = false;
    if (headers != null) request.headers.addAll(headers);
    if (body != null) request.body = body;
    final response = await http.Response.fromStream(await client.send(request));
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw AppleError('GrandSlam $operation refused an HTTP redirect.');
    }
    return response;
  }

  /// Fetches [GrandSlamEndpoints] via a `GET` to the GrandSlam lookup
  /// endpoint. No Anisette data is needed for this call (nothing exists to
  /// derive it from yet); [headers] should carry the persisted
  /// pseudo-identity/locale headers (`X-MMe-Client-Info`, `X-Mme-Device-Id`,
  /// `X-Apple-I-Locale`, `X-Apple-I-TimeZone`, `X-Apple-I-TimeZone-Offset`,
  /// `X-MMe-Country`) per xtool's `GrandSlamLookupManager.performLookup`.
  ///
  /// Not cached to disk by this function - callers are expected to cache the
  /// result in memory for the process lifetime (endpoints are stable enough
  /// to just re-fetch each run).
  static Future<GrandSlamEndpoints> fetchGrandSlamEndpoints(
    http.Client client, {
    required Map<String, String> headers,
  }) async {
    final response = await GrandSlamEndpoints.sendGrandSlamRequest(
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
    if (decoded is! Map) {
      throw AppleError(
        'GrandSlam endpoint lookup response was not a plist dictionary',
      );
    }
    final urls = decoded['urls'];
    if (urls is! Map) {
      throw AppleError('GrandSlam endpoint lookup response missing "urls"');
    }
    return GrandSlamEndpoints.fromPlistUrls(urls.cast());
  }
}

final Uri _lookupUrl = Uri.parse(
  'https://gsa.apple.com/grandslam/GsService2/lookup',
);
