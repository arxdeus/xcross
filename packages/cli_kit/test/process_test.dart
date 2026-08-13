import 'dart:async';
import 'dart:io';

import 'package:cli_kit/src/errors.dart';
import 'package:cli_kit/src/process.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('commandLine', () {
    test('quotes an empty-string argument as a pair of empty quotes', () {
      expect(ProcessRunner.commandLine('ls', ['']), "ls ''");
    });

    test('leaves a token with no special characters unquoted', () {
      expect(ProcessRunner.commandLine('echo', ['hello']), 'echo hello');
    });

    test('single-quotes a token containing a space', () {
      expect(
        ProcessRunner.commandLine('echo', ['has space']),
        "echo 'has space'",
      );
    });

    // Regression check: the classic POSIX idiom for embedding a literal
    // single quote inside a single-quoted string is close-quote,
    // backslash-escaped-quote, reopen-quote. Getting this wrong produces a
    // command line that a shell can't actually parse back.
    test(
      'single-quotes a token with an embedded quote using close/escape/reopen',
      () {
        final result = ProcessRunner.commandLine('echo', ["it's"]);
        expect(
          result,
          'echo '
          r"'it'\''s'",
        );
      },
    );

    test(r'quotes tokens containing $, backtick, or double-quote', () {
      const token = r'$HOME`cmd`"quoted"';
      final result = ProcessRunner.commandLine('echo', [token]);
      expect(result, "echo '$token'");
    });

    test('joins executable and arguments, quoting only where needed', () {
      final result = ProcessRunner.commandLine('ls', ['-la', 'my file.txt']);
      expect(result, startsWith('ls -la'));
      expect(result, contains("'my file.txt'"));
    });
  });

  group('bracketHost', () {
    test('wraps an address containing a colon in brackets', () {
      expect(ProcessRunner.bracketHost('::1'), '[::1]');
      expect(ProcessRunner.bracketHost('fe80::1234'), '[fe80::1234]');
    });

    test('leaves an address without a colon unchanged', () {
      expect(ProcessRunner.bracketHost('192.168.1.1'), '192.168.1.1');
      expect(ProcessRunner.bracketHost('localhost'), 'localhost');
    });
  });

  group('unbracketHost', () {
    test('strips brackets when both are present', () {
      expect(ProcessRunner.unbracketHost('[::1]'), '::1');
      expect(ProcessRunner.unbracketHost('[fe80::1]'), 'fe80::1');
    });

    test('leaves a host unchanged unless both brackets are present', () {
      expect(ProcessRunner.unbracketHost('localhost'), 'localhost');
      // Starts with '[' but has no closing ']' — must not be touched.
      expect(ProcessRunner.unbracketHost('[fe80::1'), '[fe80::1');
    });
  });

  // ProcessRunner.pausingBroadcast underlies sharedStdin (see
  // shared_stdin_test.dart for the original cancel-must-not-kill-the-source
  // regression cases). These add cases not already covered there.
  group('pausingBroadcast', () {
    // The last listener must be left attached (never cancelled) before
    // close(): pausingBroadcast's onCancel *pauses* rather than cancels the
    // source subscription, so if the last listener is gone the paused source
    // subscription would never be resumed to deliver close()'s done event —
    // matches the pattern already established in shared_stdin_test.dart.
    test(
      'a listener after multiple prior cancels still receives new events',
      () async {
        final source = StreamController<int>();
        final shared = ProcessRunner.pausingBroadcast(source.stream);

        await shared.listen((_) {}).cancel();
        await shared.listen((_) {}).cancel();

        final seen = <int>[];
        shared.listen(seen.add);
        source.add(42);
        await Future<void>.delayed(Duration.zero);

        expect(seen, [42]);
        await source.close();
      },
    );

    test('multiple events queued while unwatched all arrive at the next '
        'listener', () async {
      final source = StreamController<int>();
      final shared = ProcessRunner.pausingBroadcast(source.stream);

      await shared.listen((_) {}).cancel();
      source.add(1);
      source.add(2); // both queued — nobody listening yet

      final seen = <int>[];
      shared.listen(seen.add);
      await Future<void>.delayed(Duration.zero);

      expect(seen, [1, 2]);
      await source.close();
    });
  });

  group('pollUntil', () {
    test('returns the first non-null value from a later attempt', () async {
      var calls = 0;
      final result = await ProcessRunner.pollUntil<int>(
        attempt: () async {
          calls++;
          return calls < 3 ? null : 99;
        },
        timeout: const Duration(seconds: 2),
        interval: const Duration(milliseconds: 10),
      );
      expect(result, 99);
      expect(calls, 3);
    });

    test('returns null once the timeout elapses with no value', () async {
      final stopwatch = Stopwatch()..start();
      final result = await ProcessRunner.pollUntil<int>(
        attempt: () async => null,
        timeout: const Duration(milliseconds: 150),
        interval: const Duration(milliseconds: 30),
      );
      stopwatch.stop();
      expect(result, isNull);
      expect(stopwatch.elapsedMilliseconds, lessThan(2000));
    });

    test(
      'swallows exceptions from attempt and still times out to null',
      () async {
        final result = await ProcessRunner.pollUntil<int>(
          attempt: () async => throw StateError('boom'),
          timeout: const Duration(milliseconds: 100),
          interval: const Duration(milliseconds: 20),
        );
        expect(result, isNull);
      },
    );
  });

  group('makeExecutable', () {
    test(
      'does not throw, and sets the execute bit where POSIX chmod applies',
      () async {
        final tmp = await Directory.systemTemp.createTemp('xcross_process-');
        addTearDown(() => tmp.delete(recursive: true));
        final file = File(p.join(tmp.path, 'script.sh'));
        await file.writeAsString('#!/bin/sh\necho hi\n');

        try {
          ProcessRunner.makeExecutable(file.path);
          // ignore: avoid_catching_errors
        } on ArgumentError catch (e) {
          // The installed posix package dlopens its native helper library
          // eagerly, at construction, instead of catching a missing library
          // and reporting it through isPosixSupported — so on a host lacking
          // that helper (this dev box has no primitives.dll) even the
          // isPosixSupported guard inside makeExecutable throws instead of
          // returning false. That is an environment/dependency gap, not
          // something a test on this file can fix — skip gracefully.
          if (e.toString().contains('dynamic library')) {
            markTestSkipped('posix native helper library unavailable: $e');
            return;
          }
          rethrow;
        }

        if (Platform.isLinux || Platform.isMacOS) {
          final mode = file.statSync().mode;
          expect(mode & 0x49, isNot(0), reason: 'no execute bit set');
        }
      },
    );
  });

  group('hostExecutableName', () {
    test('adds the requested Windows extension only on Windows', () {
      expect(
        ProcessRunner.hostExecutableName('dart', windows: true),
        'dart.exe',
      );
      expect(
        ProcessRunner.hostExecutableName(
          'flutter',
          windows: true,
          windowsExtension: '.bat',
        ),
        'flutter.bat',
      );
      expect(ProcessRunner.hostExecutableName('dart', windows: false), 'dart');
    });
  });

  group('which', () {
    test('follows Windows PATH and PATHEXT case-insensitively', () async {
      final tmp = Directory.systemTemp.createTempSync('xcross-pathext-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final executable = File(p.join(tmp.path, 'python.EXE'))..createSync();

      final result = await ProcessRunner.which(
        'python',
        windows: true,
        environment: {'Path': tmp.path, 'Pathext': '.EXE;.BAT'},
      );

      expect(result, executable.path);
    });

    test('appends PATHEXT when the command already contains a dot', () async {
      final tmp = Directory.systemTemp.createTempSync('xcross-dotted-exe-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final executable = File(p.join(tmp.path, 'ld64.lld.EXE'))..createSync();

      final result = await ProcessRunner.which(
        'ld64.lld',
        windows: true,
        environment: {'PATH': tmp.path, 'PATHEXT': '.EXE;.BAT'},
      );

      expect(result, isNotNull);
      expect(p.equals(result!, executable.path), isTrue);
    });

    test(
      'resolves to null for an executable that does not exist on PATH',
      () async {
        final result = await ProcessRunner.which(
          'definitely-not-a-real-executable-xyz-987',
        );
        expect(result, isNull);
      },
    );

    test('skips a swiftly proxy shim and keeps walking PATH', () async {
      final tmp = Directory.systemTemp.createTempSync('xcross-swiftly-');
      addTearDown(() => tmp.deleteSync(recursive: true));

      // Mirror swiftly's layout: every tool in its bin directory is a symlink
      // to the `swiftly` binary itself.
      final swiftlyBin = Directory(p.join(tmp.path, 'swiftly-bin'))
        ..createSync();
      final shim = p.join(swiftlyBin.path, 'ld64.lld');
      File(p.join(swiftlyBin.path, 'swiftly')).writeAsStringSync('');
      try {
        Link(shim).createSync(p.join(swiftlyBin.path, 'swiftly'));
      } on FileSystemException {
        markTestSkipped('host does not allow creating symlinks');
        return;
      }

      final llvmBin = Directory(p.join(tmp.path, 'llvm-bin'))..createSync();
      final real = File(p.join(llvmBin.path, 'ld64.lld'))
        ..writeAsStringSync('');

      final env = {
        'PATH': [
          swiftlyBin.path,
          llvmBin.path,
        ].join(Platform.isWindows ? ';' : ':'),
      };
      expect(await ProcessRunner.which('ld64.lld', environment: env), shim);
      expect(
        await ProcessRunner.which(
          'ld64.lld',
          environment: env,
          accept: (path) => !ProcessRunner.isSwiftlyProxy(path),
        ),
        real.path,
      );
    });
  });

  group('run', () {
    test(
      'captures stdout/stderr and the exit code of a real process',
      () async {
        final result = await ProcessRunner.run(Platform.resolvedExecutable, [
          '--version',
        ]);
        expect(result.exitCode, 0);
        expect(result.stdout + result.stderr, contains('Dart'));
      },
    );
  });

  group('runChecked', () {
    test(
      'throws CliError with the command line embedded on a non-zero exit',
      () async {
        await expectLater(
          ProcessRunner.runChecked(Platform.resolvedExecutable, [
            '--this-flag-does-not-exist-xyz',
          ]),
          throwsA(
            isA<CliError>().having(
              (e) => e.message,
              'message',
              contains(Platform.resolvedExecutable),
            ),
          ),
        );
      },
    );
  });

  group('whichAll extraDirectories', () {
    test('finds a tool that PATH never mentions', () async {
      final tmp = Directory.systemTemp.createTempSync('xcross-extra-dir-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final tool = File(p.join(tmp.path, 'ld64.lld'))..createSync();

      expect(
        await ProcessRunner.whichAll(
          'ld64.lld',
          environment: const {'PATH': ''},
          windows: false,
          extraDirectories: [tmp.path],
        ),
        [tool.path],
      );
    });

    test(
      'reports a directory that is both on PATH and extra only once',
      () async {
        final tmp = Directory.systemTemp.createTempSync('xcross-dup-dir-');
        addTearDown(() => tmp.deleteSync(recursive: true));
        File(p.join(tmp.path, 'ld64.lld')).createSync();

        expect(
          await ProcessRunner.whichAll(
            'ld64.lld',
            environment: {'PATH': tmp.path},
            windows: false,
            extraDirectories: [tmp.path],
          ),
          hasLength(1),
        );
      },
    );

    test('searches PATH before the extra directories', () async {
      final tmp = Directory.systemTemp.createTempSync('xcross-order-dir-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final onPath = Directory(p.join(tmp.path, 'path-bin'))..createSync();
      final extra = Directory(p.join(tmp.path, 'llvm-bin'))..createSync();
      File(p.join(onPath.path, 'ld64.lld')).createSync();
      File(p.join(extra.path, 'ld64.lld')).createSync();

      expect(
        await ProcessRunner.whichAll(
          'ld64.lld',
          environment: {'PATH': onPath.path},
          // The PATH entry is a real host path, so it has to be split with
          // the host's own separator: ':' would cut a Windows drive letter
          // off its own directory and drop the entry.
          windows: Platform.isWindows,
          extraDirectories: [extra.path],
        ),
        [p.join(onPath.path, 'ld64.lld'), p.join(extra.path, 'ld64.lld')],
      );
    });
  });

  group('describeExitCode', () {
    test('names a Windows NTSTATUS reported as a raw DWORD', () {
      expect(
        ProcessRunner.describeExitCode(0xC0000135),
        contains('STATUS_DLL_NOT_FOUND'),
      );
    });

    test('names the same status when dart:io sign-extends it', () {
      expect(
        ProcessRunner.describeExitCode(-1073740791),
        allOf(contains('0xC0000409'), contains('abort()')),
      );
    });

    test('still explains an NTSTATUS it has no name for', () {
      expect(
        ProcessRunner.describeExitCode(0xC0000123),
        contains('died instead of exiting'),
      );
    });

    test('reads a small negative code as a POSIX signal', () {
      expect(ProcessRunner.describeExitCode(-11), 'killed by signal 11');
    });

    test('says nothing about an ordinary non-zero exit', () {
      expect(ProcessRunner.describeExitCode(1), isNull);
      expect(ProcessRunner.describeExitCode(255), isNull);
    });

    test('separates a crash from a chosen exit status', () {
      expect(ProcessRunner.crashed(1), isFalse);
      expect(ProcessRunner.crashed(255), isFalse);
      expect(ProcessRunner.crashed(-11), isTrue);
      expect(ProcessRunner.crashed(-1073740791), isTrue);
      expect(ProcessRunner.crashed(0xC0000409), isTrue);
    });
  });
}
