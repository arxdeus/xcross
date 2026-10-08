import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:xcross/src/shared/update/release_lookup.dart';

import 'release_http_fixtures.dart';

void main() {
  test(
    'release lookup uses supplied client and closes successful API request',
    () async {
      final client = FixtureReleaseHttpClient(
        () async => FixtureReleaseHttpResponse(body: '{"tag_name":"1.3.0"}'),
      );
      final lookup = ReleaseLookup(createClient: () => client);
      expect(
        await lookup.latestTag(environment: {'GITHUB_TOKEN': 'fixture-token'}),
        '1.3.0',
      );
      expect(client.closed, isTrue);
      expect(client.requests.single.followRedirects, isFalse);
      expect(
        client.requests.single.headers.value(HttpHeaders.authorizationHeader),
        'Bearer fixture-token',
      );
    },
  );

  test(
    'release lookup closes failed API and redirect fallback clients',
    () async {
      final first = FixtureReleaseHttpClient(
        () async => FixtureReleaseHttpResponse(statusCode: 503),
      );
      final second = FixtureReleaseHttpClient(
        () async => FixtureReleaseHttpResponse(
          statusCode: 302,
          location: 'https://github.com/$xcrossRepo/releases/tag/1.4.0',
        ),
      );
      final clients = [first, second];
      final lookup = ReleaseLookup(createClient: () => clients.removeAt(0));
      expect(await lookup.latestTag(environment: const {}), '1.4.0');
      expect(first.closed, isTrue);
      expect(second.closed, isTrue);
      expect(second.requests.single.followRedirects, isFalse);
    },
  );

  test(
    'release lookup reports injected timeouts and closes both clients',
    () async {
      final clients = <FixtureReleaseHttpClient>[];
      final lookup = ReleaseLookup(
        createClient: () {
          final client = FixtureReleaseHttpClient(
            () async => throw TimeoutException('fixture timeout'),
          );
          clients.add(client);
          return client;
        },
      );
      await expectLater(
        lookup.latestTag(environment: const {}),
        throwsA(
          predicate(
            (Object error) => error.toString().contains('fixture timeout'),
          ),
        ),
      );
      expect(clients, hasLength(2));
      expect(clients.every((client) => client.closed), isTrue);
    },
  );

  test('asset URLs point at the release download path', () {
    expect(
      xcrossAssetBaseUrl('1.3.0'),
      'https://github.com/$xcrossRepo/releases/download/1.3.0',
    );
  });

  group('tagFromReleaseUrl', () {
    test('reads the tag out of a release redirect', () {
      expect(
        ReleaseLookup.tagFromReleaseUrl(
          'https://github.com/$xcrossRepo/releases/tag/1.3.0',
        ),
        '1.3.0',
      );
      expect(
        ReleaseLookup.tagFromReleaseUrl('/arxdeus/xcross/releases/tag/v1.3.0'),
        'v1.3.0',
      );
    });

    // pathSegments percent-decodes, so a tag is only safe to interpolate into
    // a download URL after it has been checked against the release shape.
    test('rejects a tag that is not a release version', () {
      for (final tag in [
        '..%2f..%2fevil',
        'latest',
        'nightly',
        '..',
        '%2e%2e',
      ]) {
        expect(
          ReleaseLookup.tagFromReleaseUrl(
            'https://github.com/$xcrossRepo/releases/tag/$tag',
          ),
          isNull,
          reason: 'expected $tag to be refused',
        );
      }
    });

    // A repository with no releases redirects to the listing page, whose last
    // segment is "releases"; taking it would report that as the latest tag.
    test('returns null when the redirect names no release', () {
      for (final url in [
        'https://github.com/$xcrossRepo/releases',
        'https://github.com/$xcrossRepo/releases/latest',
        'https://github.com/$xcrossRepo/releases/tag/',
        'https://github.com/$xcrossRepo',
      ]) {
        expect(
          ReleaseLookup.tagFromReleaseUrl(url),
          isNull,
          reason: 'expected no tag in $url',
        );
      }
    });
  });
}
