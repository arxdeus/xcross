// Tests for the `--anisette-url` / `XCROSS_ANISETTE_URL` sign-in mode
// selection on `xcross auth`: URL validation, flag/env precedence, and the
// mutual exclusion with the local Android ADI path.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/shared/grandslam/anisette/omnisette_provider.dart';
import 'package:test/test.dart';
import 'package:xcross/src/shared/cli/basic/auth_command.dart';
import 'package:xcross/src/shared/errors/errors.dart';

import 'auth_fixture.dart';

void main() {
  group('omnisetteUrlChoice', () {
    test('defaults to the public Omnisette Mac server', () {
      expect(
        AuthCommand.omnisetteUrlChoice(
          flagValue: null,
          flagParsed: false,
          adiLibraryDirParsed: false,
        ),
        kDefaultOmnisetteUrl,
      );
    });

    test('empty flag value is rejected', () {
      expect(
        () => AuthCommand.omnisetteUrlChoice(
          flagValue: '',
          flagParsed: true,
          adiLibraryDirParsed: false,
        ),
        throwsA(
          isA<XcrossError>().having(
            (error) => error.message,
            'message',
            contains('--anisette-url requires a non-empty URL'),
          ),
        ),
      );
    });

    test('non-http(s) URLs are rejected', () {
      for (final url in ['ftp://example.test', 'example.test', 'file:///x']) {
        expect(
          () => AuthCommand.omnisetteUrlChoice(
            flagValue: url,
            flagParsed: true,
            adiLibraryDirParsed: false,
          ),
          throwsA(
            isA<XcrossError>().having(
              (error) => error.message,
              'message',
              contains('http(s) URL of an omnisette-server'),
            ),
          ),
          reason: url,
        );
      }
    });

    test('accepts a self-hosted http URL and trims whitespace', () {
      expect(
        AuthCommand.omnisetteUrlChoice(
          flagValue: '  http://localhost:8080  ',
          flagParsed: true,
          adiLibraryDirParsed: false,
        ),
        'http://localhost:8080',
      );
    });

    test('the environment variable selects the remote path', () {
      expect(
        AuthCommand.omnisetteUrlChoice(
          flagValue: null,
          flagParsed: false,
          adiLibraryDirParsed: false,
          environmentValue: 'https://omnisette.example.test',
        ),
        'https://omnisette.example.test',
      );
    });

    test('the flag wins over the environment variable', () {
      expect(
        AuthCommand.omnisetteUrlChoice(
          flagValue: 'https://flag.example.test',
          flagParsed: true,
          adiLibraryDirParsed: false,
          environmentValue: 'https://env.example.test',
        ),
        'https://flag.example.test',
      );
    });

    test('--adi-library-dir keeps the local path without an env URL', () {
      expect(
        AuthCommand.omnisetteUrlChoice(
          flagValue: null,
          flagParsed: false,
          adiLibraryDirParsed: true,
        ),
        isNull,
      );
    });

    test('--adi-library-dir conflicts with the env URL', () {
      expect(
        () => AuthCommand.omnisetteUrlChoice(
          flagValue: null,
          flagParsed: false,
          adiLibraryDirParsed: true,
          environmentValue: 'https://omnisette.example.test',
        ),
        throwsA(
          isA<XcrossError>().having(
            (error) => error.message,
            'message',
            contains('not both'),
          ),
        ),
      );
    });

    test('the anisette flag wins over --adi-library-dir', () {
      expect(
        AuthCommand.omnisetteUrlChoice(
          flagValue: 'https://omnisette.example.test',
          flagParsed: true,
          adiLibraryDirParsed: true,
        ),
        'https://omnisette.example.test',
      );
    });
  });

  group('legacy local ADI host gate', () {
    // Only --adi-library-dir still needs native libraries; Omnisette default
    // does not. The ABI gate still rejects unsupported hosts on that path.
    for (final abi in [Abi.windowsIA32, Abi.linuxArm, Abi.androidArm64]) {
      test('rejects $abi', () {
        expect(() => AuthCommand.requireAppleIdHost(abi), throwsA(anything));
      });
    }

    test('fixture builds with the restored ADI seams', () {
      expect(authFixture(), isNotNull);
    });
  });

  group('appleIdLoginFailureMessage', () {
    const docs = 'https://xcross.sh/docs/authentication/#remote-anisette';

    test('local ADI failure suggests the Omnisette default', () {
      final message = AuthCommand.appleIdLoginFailureMessage(
        Exception('gsa refused'),
        anisetteUrl: null,
      );
      expect(
        message,
        contains('Apple ID login failed: Exception: gsa refused'),
      );
      expect(message, contains(docs));
      expect(message, contains('--anisette-url'));
      expect(message, contains('Omit --adi-library-dir'));
      expect(message, isNot(contains('unreachable')));
    });

    test('local -80046 names the Android rejection', () {
      final message = AuthCommand.appleIdLoginFailureMessage(
        Exception('status -80046'),
        anisetteUrl: null,
      );
      expect(message, contains('Apple rejects Android anisette (-80046)'));
    });

    test('unreachable remote suggests trying another server', () {
      final message = AuthCommand.appleIdLoginFailureMessage(
        const SocketException('Connection refused'),
        anisetteUrl: 'https://mac-ani.example.test',
      );
      expect(message, contains('unreachable'));
      expect(message, contains(docs));
      expect(message, contains('--anisette-url'));
    });

    test('timeout on remote is treated as unreachable', () {
      final message = AuthCommand.appleIdLoginFailureMessage(
        TimeoutException('slow'),
        anisetteUrl: 'https://mac-ani.example.test',
      );
      expect(message, contains('unreachable'));
    });

    test('non-connectivity remote failure stays short', () {
      final message = AuthCommand.appleIdLoginFailureMessage(
        Exception('bad password'),
        anisetteUrl: 'https://mac-ani.example.test',
      );
      expect(message, 'Apple ID login failed: Exception: bad password');
    });
  });
}
