import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:test/test.dart';
import 'package:xcross/src/update/release_lookup.dart';
import 'package:xcross/src/update/update_check.dart';

import '../host_operations_fixtures.dart';
import 'release_http_fixtures.dart';

void main() {
  test(
    'eligibility uses supplied terminal metadata rather than ambient console',
    () {
      final host = LinuxHost();
      final lookup = ReleaseLookup(
        createClient: () => throw StateError('unexpected lookup'),
      );
      final terminal = UpdateCheck(
        host,
        log: fixtureLog(),
        releaseLookup: lookup,
        outputHasTerminal: true,
        released: true,
      );
      final redirected = UpdateCheck(
        host,
        log: fixtureLog(),
        releaseLookup: lookup,
        outputHasTerminal: false,
        released: true,
      );
      expect(terminal.isEnabled(ownsStdout: false), isTrue);
      expect(redirected.isEnabled(ownsStdout: false), isFalse);
      expect(terminal.isEnabled(ownsStdout: true), isFalse);
    },
  );

  test(
    'cache refresh reads and writes only selected mapped filesystem',
    () async {
      final root = Directory.systemTemp.createTempSync('mapped-update-check-');
      addTearDown(() => root.deleteSync(recursive: true));
      final mapped = FixtureMappedFileSystem(root);
      final host = LinuxHost(
        fileSystem: mapped,
        environment: {
          'XDG_CONFIG_HOME': '/logical/config',
          'HOME': '/logical/home',
        },
      );
      var clients = 0;
      final lookup = ReleaseLookup(
        createClient: () {
          clients++;
          return FixtureReleaseHttpClient(
            () async =>
                FixtureReleaseHttpResponse(body: '{"tag_name":"9.8.7"}'),
          );
        },
      );
      final check = UpdateCheck(
        host,
        log: fixtureLog(),
        releaseLookup: lookup,
        outputHasTerminal: true,
      );
      await check.refreshIfStale();
      final cache = File(mapped.physical(check.cachePath()));
      expect((jsonDecode(cache.readAsStringSync()) as Map)['latest'], '9.8.7');
      expect(mapped.touched, contains(check.cachePath()));
      await check.refreshIfStale();
      expect(clients, 1);
    },
  );
}
