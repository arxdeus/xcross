// Tests for the `--anisette-url` / `XCROSS_ANISETTE_URL` sign-in mode
// selection on `xcross auth`: URL validation, flag/env precedence, and the
// mutual exclusion with the local Android ADI path.
import 'dart:ffi';

import 'package:test/test.dart';
import 'package:xcross/src/shared/cli/basic/auth_command.dart';
import 'package:xcross/src/shared/errors/errors.dart';

import 'auth_fixture.dart';

void main() {
  group('omnisetteUrlChoice', () {
    test('defaults to the local Android ADI path', () {
      expect(
        AuthCommand.omnisetteUrlChoice(
          flagValue: null,
          flagParsed: false,
          adiLibraryDirParsed: false,
        ),
        isNull,
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
          isA<XcrossError>()
              .having(
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

  group('host support stays local by default', () {
    // The remote path needs no native libraries, but the default local one
    // still refuses unsupported hosts before prompting for credentials.
    for (final abi in [Abi.windowsIA32, Abi.linuxArm, Abi.androidArm64]) {
      test('rejects $abi', () {
        expect(() => AuthCommand.requireAppleIdHost(abi), throwsA(anything));
      });
    }

    test('fixture builds with the restored ADI seams', () {
      expect(authFixture(), isNotNull);
    });
  });
}
