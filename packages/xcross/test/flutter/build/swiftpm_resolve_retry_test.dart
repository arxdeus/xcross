import 'package:cli_kit/shared/process/process_models.dart';
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/network_retry.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_repair.dart';

import 'swiftpm_test_context.dart';

final _swiftPmRuntime = testSwiftPmRuntime();

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
          SwiftPmNetworkRetry.isTransientNetworkFailure(error),
          isTrue,
          reason: error,
        );
      }
    });

    test('recognizes binary artifact download failures', () {
      const grpc =
          "error: failed downloading 'https://dl.google.com/grpc.zip' which is "
          "required by binary target 'grpc': downloadError(\"Error "
          r'Domain=NSURLErrorDomain Code=-1001 \"(null)\"")';
      const absl =
          "error: failed downloading 'https://dl.google.com/absl.zip' which is "
          "required by binary target 'absl': downloadError(\"Error "
          'Domain=NSURLErrorDomain '
          r'Code=-1 \"(null)\"UserInfo={NSLocalizedDescription=OpenSSL '
          'SSL_connect: SSL_ERROR_SYSCALL in '
          'connection to dl.google.com:443 }")';
      const observed = [
        grpc,
        absl,
        r'downloadError("Error Domain=NSURLErrorDomain Code=-1005 \"(null)\"")',
        r'downloadError("Error Domain=NSURLErrorDomain Code=-1004 \"(null)\"")',
      ];
      for (final error in observed) {
        expect(
          SwiftPmNetworkRetry.isTransientNetworkFailure(error),
          isTrue,
          reason: error,
        );
      }
    });

    test('leaves non-network download failures alone', () {
      const checksum =
          "error: checksum of downloaded artifact of binary target 'grpc' does "
          'not match checksum specified by the manifest';
      const real = [
        r'downloadError("Error Domain=NSURLErrorDomain Code=-1002 \"(null)\"")',
        r'downloadError("Error Domain=NSURLErrorDomain Code=-10010 \"(null)\"")',
        checksum,
      ];
      for (final error in real) {
        expect(
          SwiftPmNetworkRetry.isTransientNetworkFailure(error),
          isFalse,
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
          SwiftPmNetworkRetry.isTransientNetworkFailure(error),
          isFalse,
          reason: error,
        );
      }
    });

    test('does not treat our own timeout kill as retryable', () {
      // Retrying would multiply the very stall the timeout exists to cut
      // short, turning a bounded failure back into an unbounded one.
      expect(
        SwiftPmNetworkRetry.isTransientNetworkFailure(
          'command timed out after 1800s and was killed: swift package resolve',
        ),
        isFalse,
      );
    });
  });

  group('transient resolve failure classification', () {
    // Seen twice on windows-2022 CI on 2026-10-10: swift-package.exe died
    // right after the last checkout, and the next run of the same build
    // passed.
    const crash =
        'command failed (-1073741819: 0xC0000005 STATUS_ACCESS_VIOLATION, a '
        r'bad pointer dereference): C:\Swift\usr\bin\swift-package.EXE '
        r'--package-path C:\plugins resolve';

    test('retries a SwiftPM access violation on resolve', () {
      expect(SwiftPmNetworkRetry.isTransientResolveFailure(crash), isTrue);
      expect(
        SwiftPmNetworkRetry.isTransientNetworkFailure(crash),
        isFalse,
        reason: 'crashes are only retried where resolve opts in',
      );
    });

    test('still retries network failures', () {
      expect(
        SwiftPmNetworkRetry.isTransientResolveFailure(
          'Recv failure: Connection was reset',
        ),
        isTrue,
      );
    });

    test('leaves real failures and timeouts alone', () {
      const timeout =
          'command failed (-1073741819: 0xC0000005 STATUS_ACCESS_VIOLATION) '
          'timed out after 1800s and was killed';
      const missingDll =
          'command failed (-1073741515: 0xC0000135 STATUS_DLL_NOT_FOUND, a DLL '
          'it needs is not on PATH): swift-package.EXE resolve';
      for (final error in [
        "error: no such module 'Flutter'",
        timeout,
        missingDll,
      ]) {
        expect(
          SwiftPmNetworkRetry.isTransientResolveFailure(error),
          isFalse,
          reason: error,
        );
      }
    });

    test('a crash is retried when the caller opts in', () async {
      var attempts = 0;
      await _swiftPmRuntime.networkRetry.retryingTransientNetworkFailure(
        () async {
          if (++attempts == 1) throw Exception(crash);
        },
        label: 'resolve',
        delay: (_) async {},
        retryable: SwiftPmNetworkRetry.isTransientResolveFailure,
      );
      expect(attempts, 2);
    });
  });

  group('retryingTransientNetworkFailure', () {
    test('retries a transient failure and then succeeds', () async {
      var attempts = 0;
      final waits = <Duration>[];
      await _swiftPmRuntime.networkRetry.retryingTransientNetworkFailure(
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
        _swiftPmRuntime.networkRetry.retryingTransientNetworkFailure(
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
        _swiftPmRuntime.networkRetry.retryingTransientNetworkFailure(
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
      await _swiftPmRuntime.networkRetry.retryingTransientNetworkFailure(
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
      final text = SwiftPmSourceRepair.resolveDiagnostics(
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
      final text = SwiftPmSourceRepair.resolveDiagnostics(
        const CapturedProcess(
          1,
          'error: Recv failure: Connection was reset',
          '',
        ),
      );
      expect(SwiftPmNetworkRetry.isTransientNetworkFailure(text), isTrue);
    });

    test('omits an empty stream instead of leaving a blank line', () {
      final text = SwiftPmSourceRepair.resolveDiagnostics(
        const CapturedProcess(1, '', 'only stderr'),
      );
      expect(text, 'only stderr');
    });
  });

  group('resolveWithFinalBinaryRecovery', () {
    test('recovers and retries an ordinary resolve failure', () async {
      var resolves = 0;
      var recovered = false;
      await _swiftPmRuntime.binaryRecovery.resolveWithFinalBinaryRecovery(
        resolve: () async {
          if (resolves++ == 0) throw StateError('missing binary artifact');
        },
        recover: () async => recovered = true,
      );
      expect(resolves, 2);
      expect(recovered, isTrue);
    });

    test(
      'rethrows the original failure when recovery has no evidence',
      () async {
        final original = StateError('original');
        var resolves = 0;
        await expectLater(
          _swiftPmRuntime.binaryRecovery.resolveWithFinalBinaryRecovery(
            resolve: () {
              resolves++;
              throw original;
            },
            recover: () async => false,
          ),
          throwsA(same(original)),
        );
        expect(resolves, 1);
      },
    );

    test('a second resolve failure is terminal', () async {
      final second = StateError('second');
      var resolves = 0;
      await expectLater(
        _swiftPmRuntime.binaryRecovery.resolveWithFinalBinaryRecovery(
          resolve: () {
            if (resolves++ == 0) throw StateError('first');
            throw second;
          },
          recover: () async => true,
        ),
        throwsA(same(second)),
      );
      expect(resolves, 2);
    });

    test(
      'does not run a resolve again after we killed it for timing out',
      () async {
        // Re-running waits out the same stall, which is how the Windows job
        // kept burning to the job limit even once the timeout fired.
        var resolves = 0;
        var recovered = false;
        await expectLater(
          _swiftPmRuntime.binaryRecovery.resolveWithFinalBinaryRecovery(
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
      },
    );

    test('treats the resolve-specific timeout message as terminal too', () {
      expect(
        SwiftPmBinaryRecovery.isResolveTimeout(
          StateError(
            r'Resolving SwiftPM dependencies in C:\p took longer than 30 '
            'minutes and was stopped.',
          ),
        ),
        isTrue,
      );
      expect(
        SwiftPmBinaryRecovery.isResolveTimeout(
          StateError('error: no such module'),
        ),
        isFalse,
      );
    });
  });
}
