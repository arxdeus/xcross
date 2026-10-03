import 'dart:convert';
import 'dart:io';

import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/internal/http_result.dart';
import 'package:xcross/src/version.dart';

/// GitHub repository publishing the xcross releases.
const xcrossRepo = 'arxdeus/xcross';

/// Base URL for a release's downloadable assets.
String xcrossAssetBaseUrl(String tag) =>
    'https://github.com/$xcrossRepo/releases/download/$tag';

/// Discovers the newest published release tag.
abstract final class ReleaseLookup {
  static const _apiUrl =
      'https://api.github.com/repos/$xcrossRepo/releases/latest';
  static const _htmlUrl = 'https://github.com/$xcrossRepo/releases/latest';

  /// Returns the newest release tag, e.g. `1.3.0`.
  ///
  /// Tries the REST API first, then falls back to the `releases/latest`
  /// redirect the installers already rely on, which needs no API quota.
  static Future<String> latestTag({
    required Map<String, String> environment,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final failures = <String>[];
    for (final attempt in [
      (Duration timeout) => _fromApi(timeout, environment),
      (Duration timeout) => _fromRedirect(timeout, environment),
    ]) {
      try {
        final tag = await attempt(timeout);
        if (tag != null && tag.isNotEmpty) return tag;
        failures.add('empty response');
      } on Object catch (e) {
        failures.add('$e');
      }
    }
    throw XcrossError(
      'could not determine the latest xcross release: ${failures.join('; ')}',
    );
  }

  /// Redirects are not followed here: `dart:io` replays the request headers on
  /// the redirect target, which would hand `GITHUB_TOKEN` to whatever host the
  /// `Location` names. The endpoint does not redirect in practice, and the
  /// unauthenticated fallback covers it if that ever changes.
  static Future<String?> _fromApi(
    Duration timeout,
    Map<String, String> environment,
  ) async {
    final body = await _get(
      _apiUrl,
      timeout: timeout,
      environment: environment,
      followRedirects: false,
      headers: {'Accept': 'application/vnd.github+json'},
      readBody: true,
    );
    final decoded = jsonDecode(body.body ?? '');
    if (decoded is! Map<String, Object?>) return null;
    final tag = decoded['tag_name'];
    return tag is String ? tag : null;
  }

  /// `releases/latest` 302s to `releases/tag/<tag>`, so the tag is the segment
  /// after `tag`.
  ///
  /// A repository with no releases redirects to the plain `releases` listing
  /// instead, which is why the `tag` segment has to be matched rather than the
  /// last segment simply taken.
  static Future<String?> _fromRedirect(
    Duration timeout,
    Map<String, String> environment,
  ) async {
    final response = await _get(
      _htmlUrl,
      timeout: timeout,
      environment: environment,
      followRedirects: false,
      headers: const {},
      readBody: false,
    );
    final location = response.location;
    return location == null ? null : tagFromReleaseUrl(location);
  }

  /// Extracts `<tag>` from a `.../releases/tag/<tag>` URL, or null when the
  /// URL does not name a release.
  ///
  /// [Uri.pathSegments] percent-decodes, so the result is checked against the
  /// release-tag shape before it can reach a download URL.
  static String? tagFromReleaseUrl(String url) {
    final segments = Uri.parse(url).pathSegments;
    final marker = segments.lastIndexOf('tag');
    if (marker < 0 || marker + 1 >= segments.length) return null;
    final tag = segments[marker + 1];
    return _tagShape.hasMatch(tag) ? tag : null;
  }

  static final _tagShape = RegExp(r'^v?[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*$');

  static Future<HttpResult> _get(
    String url, {
    required Duration timeout,
    required Map<String, String> environment,
    required bool followRedirects,
    required Map<String, String> headers,
    required bool readBody,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
      request.followRedirects = followRedirects;
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      headers.forEach(request.headers.set);

      // A token is optional; it only raises the 60/hour anonymous rate limit
      // that CI and shared-IP users hit first.
      final token = environment['GITHUB_TOKEN'];
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }

      final response = await request.close().timeout(timeout);
      final isRedirect =
          response.statusCode >= 300 && response.statusCode < 400;
      if (response.statusCode >= 400) {
        await response.drain<void>();
        throw XcrossError('HTTP ${response.statusCode} for $url');
      }
      if (!readBody || isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        return HttpResult(location: location);
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      return HttpResult(body: body);
    } finally {
      client.close(force: true);
    }
  }

  static String get _userAgent => 'xcross/${XcrossVersion.current}';
}
