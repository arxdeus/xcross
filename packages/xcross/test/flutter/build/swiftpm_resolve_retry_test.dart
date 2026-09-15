import 'package:cli_kit/cli_kit.dart';
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';

/// Resolving the plugin graph pulls from a dozen GitHub repositories. A reset
/// or refused connection on any one of them used to fail the whole Windows
/// build, even though the same fetch succeeds moments later.
void main() {
  group('transient network failure classification', () {
    test('recognizes the errors seen while resolving SwiftPM dependencies', () {
      const leveldb =
          "fatal: unable to access 'https://github.com/firebase/leveldb.git/': "
          'Recv failure: Connection was reset';
      const promises =
          "fatal: unable to access 'https://github.com/google/promises.git/': "
          'Failed to connect to github.com:443 after 21083 ms: '
          'Could not connect to server';
      const observed = [
        leveldb,
        promises,
        'error: RPC failed; curl 56 GnuTLS recv error',
        'fatal: The remote end hung up unexpectedly',
        'fatal: early EOF',
        'ssh: Could not resolve hostname github.com',
      ];
      for (final error in observed) {
        expect(
          GeneratedPluginsPackage.isTransientNetworkFailure(error),
          isTrue,
          reason: error,
        );
      }
    });

    test('leaves real build failures alone', () {
      const real = [
        "error: no such module 'Flutter'",
        'error: Package.swift:12:3: cannot find type Target in scope',
        'error: the manifest is malformed',
        'Cannot resolve SwiftPM dependencies: product X not found',
      ];
      for (final error in real) {
        expect(
          GeneratedPluginsPackage.isTransientNetworkFailure(error),
          isFalse,
          reason: error,
        );
      }
    });

    test('does not treat our own timeout kill as retryable', () {
      // Retrying would multiply the very stall the timeout exists to cut
      // short, turning a bounded failure back into an unbounded one.
      expect(
        GeneratedPluginsPackage.isTransientNetworkFailure(
          'command timed out after 1800s and was killed: swift package resolve',
        ),
        isFalse,
      );
    });
  });

  group('retryingTransientNetworkFailure', () {
    test('retries a transient failure and then succeeds', () async {
      var attempts = 0;
      final waits = <Duration>[];
      await GeneratedPluginsPackage.retryingTransientNetworkFailure(
        () async {
          attempts++;
          if (attempts < 3) {
            throw Exception('Recv failure: Connection was reset');
          }
        },
        label: 'resolve',
        delay: (duration) async => waits.add(duration),
      );

      expect(attempts, 3);
      // Backoff grows, so a struggling remote is not hammered.
      expect(waits, [const Duration(seconds: 5), const Duration(seconds: 10)]);
    });

    test('gives up after the configured number of attempts', () async {
      var attempts = 0;
      await expectLater(
        GeneratedPluginsPackage.retryingTransientNetworkFailure(
          () {
            attempts++;
            throw Exception('Could not connect to server');
          },
          label: 'resolve',
          delay: (_) async {},
        ),
        throwsA(isA<Exception>()),
      );
      expect(attempts, 3);
    });

    test('fails fast on a real error instead of retrying it', () async {
      var attempts = 0;
      await expectLater(
        GeneratedPluginsPackage.retryingTransientNetworkFailure(
          () {
            attempts++;
            throw Exception("no such module 'Flutter'");
          },
          label: 'resolve',
          delay: (_) async {},
        ),
        throwsA(isA<Exception>()),
      );
      expect(attempts, 1, reason: 'a genuine build error must not be retried');
    });

    test('does not delay when the first attempt works', () async {
      var called = false;
      await GeneratedPluginsPackage.retryingTransientNetworkFailure(
        () async {},
        label: 'resolve',
        delay: (_) async => called = true,
      );
      expect(called, isFalse);
    });
  });

  group('resolveDiagnostics', () {
    test('reports the stdout diagnostic SwiftPM failures are explained on', () {
      // The Windows CI failure printed fetch progress on stderr and the
      // reason on stdout, so a stderr-only message ended on a successful
      // "Computed ..." line and never said what went wrong.
      final text = GeneratedPluginsPackage.resolveDiagnostics(
        const CapturedProcess(
          1,
          'error: Dependencies could not be resolved because no versions '
              "of 'sdwebimage' match the requirement",
          'Computed https://github.com/SDWebImage/SDWebImage.git at 5.21.7',
        ),
      );
      expect(text, contains('no versions of'));
      expect(text, contains('Computed https://github.com'));
    });

    test('retries a transient failure SwiftPM reported on stdout', () {
      final text = GeneratedPluginsPackage.resolveDiagnostics(
        const CapturedProcess(1, 'error: Recv failure: Connection was reset', ''),
      );
      expect(
        GeneratedPluginsPackage.isTransientNetworkFailure(text),
        isTrue,
      );
    });

    test('omits an empty stream instead of leaving a blank line', () {
      final text = GeneratedPluginsPackage.resolveDiagnostics(
        const CapturedProcess(1, '', 'only stderr'),
      );
      expect(text, 'only stderr');
    });
  });

  group('resolveWithFinalBinaryRecovery', () {
    test('recovers and retries an ordinary resolve failure', () async {
      var resolves = 0;
      var recovered = false;
      await GeneratedPluginsPackage.resolveWithFinalBinaryRecovery(
        resolve: () async {
          if (resolves++ == 0) throw StateError('missing binary artifact');
        },
        recover: () async => recovered = true,
      );
      expect(resolves, 2);
      expect(recovered, isTrue);
    });

    test('does not run a resolve again after we killed it for timing out',
        () async {
      // Re-running waits out the same stall, which is how the Windows job
      // kept burning to the job limit even once the timeout fired.
      var resolves = 0;
      var recovered = false;
      await expectLater(
        GeneratedPluginsPackage.resolveWithFinalBinaryRecovery(
          resolve: () {
            resolves++;
            throw StateError(
              'command timed out after 1800s and was killed: swift-package',
            );
          },
          recover: () async {
            recovered = true;
            return true;
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(resolves, 1);
      expect(recovered, isFalse);
    });

    test('treats the resolve-specific timeout message as terminal too', () {
      expect(
        GeneratedPluginsPackage.isResolveTimeout(
          StateError(
            r'Resolving SwiftPM dependencies in C:\p took longer than 30 '
            'minutes and was stopped.',
          ),
        ),
        isTrue,
      );
      expect(
        GeneratedPluginsPackage.isResolveTimeout(
          StateError('error: no such module'),
        ),
        isFalse,
      );
    });
  });
}
