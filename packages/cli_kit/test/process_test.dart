import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/composition/native_host.dart';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/shared/posix_paths.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/host/windows/windows_paths.dart';
import 'package:cli_kit/shared/errors/errors.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:cli_kit/src/host/windows/windows_batch.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/test_log_output.dart';
import 'support/test_process_io.dart';

void main() {
  final io = TestProcessIo();
  tearDownAll(io.close);
  final log = Log(output: TestLogOutput(emit: print));
  final nativeHost = detectPlatformHost();
  late ProcessRunner<PlatformHostInterface> runner;
  setUp(
    () => runner = ProcessRunner(
      nativeHost,
      log: log,
      stdinStream: io.input,
      stdoutSink: io.output,
      stderrSink: io.error,
    ),
  );

  ProcessRunner<PlatformHostInterface> windowsRunner() => ProcessRunner(
    WindowsHost(
      environment: nativeHost.environment.values,
      paths: WindowsPaths(context: nativeHost.paths.context),
      fileSystem: nativeHost.fileSystem,
    ),
    log: log,
    configuration: runner.configuration,
    stdinStream: io.input,
    stdoutSink: io.output,
    stderrSink: io.error,
  );
  ProcessRunner<PlatformHostInterface> posixRunner() => ProcessRunner(
    LinuxHost(
      environment: nativeHost.environment.values,
      paths: PosixPaths(context: nativeHost.paths.context),
      fileSystem: nativeHost.fileSystem,
    ),
    log: log,
    configuration: runner.configuration,
    stdinStream: io.input,
    stdoutSink: io.output,
    stderrSink: io.error,
  );

  group('commandLine', () {
    test('displays empty arguments explicitly', () {
      expect(ProcessRunner.commandLine('ls', ['']), 'ls ""');
    });

    test('leaves plain tokens readable', () {
      expect(ProcessRunner.commandLine('echo', ['hello']), 'echo hello');
    });

    test('uses JSON string escapes for display, not shell syntax', () {
      for (final token in [r'$HOME`cmd`"quoted"', 'line\nbreak', 'tab\there']) {
        expect(
          ProcessRunner.commandLine('echo', [token]),
          'echo ${jsonEncode(token)}',
        );
      }
    });

    test('keeps native path separators readable', () {
      expect(
        ProcessRunner.commandLine(r'C:\dart-sdk\bin\dart.exe', ['--flag']),
        r'C:\dart-sdk\bin\dart.exe --flag',
      );
      expect(
        ProcessRunner.commandLine('echo', [r'C:\Program Files\tool', "it's"]),
        r'echo "C:\Program Files\tool" "it'
        "'"
        's"',
      );
    });

    test('formats executable and arguments consistently', () {
      expect(
        ProcessRunner.commandLine('my tool', ['-la', 'my file.txt']),
        '"my tool" -la "my file.txt"',
      );
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

    test('stops early once cancelled, long before the timeout', () async {
      var calls = 0;
      var stop = false;
      final stopwatch = Stopwatch()..start();
      final result = await ProcessRunner.pollUntil<int>(
        attempt: () async {
          calls++;
          if (calls == 2) stop = true;
          return null;
        },
        cancelled: () => stop,
        timeout: const Duration(seconds: 30),
        interval: const Duration(milliseconds: 10),
      );
      stopwatch.stop();
      expect(result, isNull);
      expect(calls, 2, reason: 'no attempt after cancellation');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('does not attempt at all when already cancelled', () async {
      var calls = 0;
      final result = await ProcessRunner.pollUntil<int>(
        attempt: () async => ++calls,
        cancelled: () => true,
        timeout: const Duration(seconds: 30),
        interval: const Duration(milliseconds: 10),
      );
      expect(result, isNull);
      expect(calls, 0);
    });
  });

  group('makeExecutable', () {
    test(
      'does not throw, and sets the execute bit where POSIX chmod applies',
      () async {
        final tmp = await Directory.systemTemp.createTemp('xcross_process-');
        addTearDown(() => tmp.delete(recursive: true));
        final file = File(p.join(tmp.path, 'script.sh'));
        await file.writeAsString('#!/bin/sh\necho hi\n');

        expect(() => runner.makeExecutable(file.path), returnsNormally);

        if (Platform.isLinux || Platform.isMacOS) {
          final mode = file.statSync().mode;
          expect(mode & 0x49, isNot(0), reason: 'no execute bit set');
        }
      },
    );
  });

  group('hostExecutableName', () {
    test('adds the requested Windows extension only on Windows', () {
      expect(windowsRunner().hostExecutableName('dart'), 'dart.exe');
      expect(
        windowsRunner().hostExecutableName('flutter', extension: '.bat'),
        'flutter.bat',
      );
      expect(posixRunner().hostExecutableName('dart'), 'dart');
    });
  });

  group('which', () {
    test('follows Windows PATH and PATHEXT case-insensitively', () async {
      final tmp = Directory.systemTemp.createTempSync('xcross-pathext-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final executable = File(p.join(tmp.path, 'python.EXE'))..createSync();

      final result = await windowsRunner().which(
        'python',
        environment: {'Path': tmp.path, 'Pathext': '.EXE;.BAT'},
      );

      expect(result, executable.path);
    });

    test('appends PATHEXT when the command already contains a dot', () async {
      final tmp = Directory.systemTemp.createTempSync('xcross-dotted-exe-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final executable = File(p.join(tmp.path, 'ld64.lld.EXE'))..createSync();

      final result = await windowsRunner().which(
        'ld64.lld',
        environment: {'PATH': tmp.path, 'PATHEXT': '.EXE;.BAT'},
      );

      expect(result, isNotNull);
      expect(p.equals(result!, executable.path), isTrue);
    });

    test(
      'resolves to null for an executable that does not exist on PATH',
      () async {
        final result = await runner.which(
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
      expect(await runner.which('ld64.lld', environment: env), shim);
      expect(
        await runner.which(
          'ld64.lld',
          environment: env,
          accept: (path) => !runner.isSwiftlyProxy(path),
        ),
        real.path,
      );
    });
  });

  group('configured process lookup', () {
    test('copies inputs and isolates runner configuration', () {
      final tools = {'dart': Platform.resolvedExecutable};
      final environment = {'DECLARED': 'yes'};
      runner = ProcessRunner(
        nativeHost,
        log: log,
        configuration: ProcessConfiguration(
          normalizedTools: tools,
          effectiveChildEnvironment: environment,
        ),
        stdinStream: io.input,
        stdoutSink: io.output,
        stderrSink: io.error,
      );
      tools.clear();
      environment.clear();

      expect(runner.configuration?.normalizedTools, contains('dart'));
      expect(
        runner.configuration?.effectiveChildEnvironment,
        containsPair('DECLARED', 'yes'),
      );
      runner = ProcessRunner(
        nativeHost,
        log: log,
        stdinStream: io.input,
        stdoutSink: io.output,
        stderrSink: io.error,
      );
      expect(runner.configuration, isNull);
    });

    test(
      'uses exact extension-aware overrides before configured PATH',
      () async {
        const configured = '/declared/python.exe';
        runner = ProcessRunner(
          nativeHost,
          log: log,
          configuration: ProcessConfiguration(
            normalizedTools: const {'python': configured},
            effectiveChildEnvironment: const {
              'PATH': '/directory/that/must/not/be/searched',
              'PATHEXT': '.EXE;.BAT',
            },
          ),
          stdinStream: io.input,
          stdoutSink: io.output,
          stderrSink: io.error,
        );

        expect(await windowsRunner().which('python'), configured);
        expect(await windowsRunner().whichAll('python.exe'), [configured]);
        expect(
          await windowsRunner().which(
            'python',
            accept: (_) => false,
            extraDirectories: [p.dirname(Platform.resolvedExecutable)],
          ),
          isNull,
        );
        expect(await posixRunner().which('dart'), isNull);
      },
    );

    test('run resolves an explicit bare executable override', () async {
      runner = ProcessRunner(
        nativeHost,
        log: log,
        configuration: ProcessConfiguration(
          normalizedTools: {'dart': Platform.resolvedExecutable},
          effectiveChildEnvironment: const {'XCROSS_TEST': '1'},
        ),
        stdinStream: io.input,
        stdoutSink: io.output,
        stderrSink: io.error,
      );

      expect((await runner.run('dart', const ['--version'])).exitCode, 0);
      expect(runner.run('missing', const []), throwsA(isA<ProcessException>()));
    });

    test('explicit tools override toolchain directories', () async {
      final temporary = Directory.systemTemp.createTempSync('toolchains-');
      addTearDown(() => temporary.deleteSync(recursive: true));
      final llvm = Directory(p.join(temporary.path, 'llvm'))..createSync();
      File(p.join(llvm.path, 'clang')).createSync();
      const explicit = '/explicit/clang';
      runner = ProcessRunner(
        nativeHost,
        log: log,
        configuration: ProcessConfiguration(
          normalizedTools: const {'clang': explicit},
          toolchainDirectories: {
            'llvm': [llvm.path],
          },
          effectiveChildEnvironment: const {},
        ),
        stdinStream: io.input,
        stdoutSink: io.output,
        stderrSink: io.error,
      );

      expect(await runner.which('clang'), explicit);
    });

    test('resolves known Swift and LLVM toolchain executables', () async {
      final temporary = Directory.systemTemp.createTempSync('toolchains-');
      addTearDown(() => temporary.deleteSync(recursive: true));
      final swift = Directory(p.join(temporary.path, 'swift'))..createSync();
      final llvm = Directory(p.join(temporary.path, 'llvm'))..createSync();
      final path = Directory(p.join(temporary.path, 'path'))..createSync();
      final swiftCompiler = File(p.join(swift.path, 'swiftc'))..createSync();
      final clang = File(p.join(llvm.path, 'clang'))..createSync();
      final llvmStrip = File(p.join(llvm.path, 'llvm-strip'))..createSync();
      File(p.join(path.path, 'clang')).createSync();
      runner = ProcessRunner(
        nativeHost,
        log: log,
        configuration: ProcessConfiguration(
          normalizedTools: const {},
          toolchainDirectories: {
            'swift': [swift.path],
            'llvm': [llvm.path],
          },
          effectiveChildEnvironment: {'PATH': path.path},
        ),
        stdinStream: io.input,
        stdoutSink: io.output,
        stderrSink: io.error,
      );

      expect(await runner.which('swiftc'), swiftCompiler.path);
      expect(await runner.which('clang'), clang.path);
      expect(await runner.which('cc'), clang.path);
      expect(await runner.which('llvm-strip'), llvmStrip.path);
    });

    test('can bypass configured tools and search PATH directly', () async {
      final temporary = Directory.systemTemp.createTempSync('process-path-');
      addTearDown(() => temporary.deleteSync(recursive: true));
      final pathTool = File(p.join(temporary.path, 'clang'))..createSync();
      runner = ProcessRunner(
        nativeHost,
        log: log,
        configuration: ProcessConfiguration(
          normalizedTools: const {'clang': '/configured/clang'},
          effectiveChildEnvironment: {'PATH': temporary.path},
        ),
        stdinStream: io.input,
        stdoutSink: io.output,
        stderrSink: io.error,
      );

      expect(
        await runner.which('clang', useConfiguration: false),
        pathTool.path,
      );
    });

    test('falls back to PATH for an unspecified tool', () async {
      final directory = p.dirname(Platform.resolvedExecutable);
      final name = p.basenameWithoutExtension(Platform.resolvedExecutable);
      runner = ProcessRunner(
        nativeHost,
        log: log,
        configuration: ProcessConfiguration(
          normalizedTools: const {},
          effectiveChildEnvironment: {'PATH': directory},
        ),
        stdinStream: io.input,
        stdoutSink: io.output,
        stderrSink: io.error,
      );

      expect(await runner.which(name), isNotNull);
      expect(await runner.locateTool(name), isNotEmpty);
    });
  });

  group('effectiveEnvironment', () {
    test('reads differently cased Windows environment keys', () {
      expect(
        windowsRunner().environmentValue(const {'Path': 'configured'}, 'PATH'),
        'configured',
      );
      expect(
        windowsRunner().environmentValue(const {
          'Path': 'old',
          'PATH': 'new',
        }, 'PATH'),
        'new',
      );
    });

    test('preserves host environment without configuration', () {
      expect(runner.effectiveEnvironment, same(nativeHost.environment.values));
    });

    test('exposes only configured child environment', () {
      runner = ProcessRunner(
        nativeHost,
        log: log,
        configuration: ProcessConfiguration(
          normalizedTools: const {},
          effectiveChildEnvironment: const {'SAFE': 'value'},
        ),
        stdinStream: io.input,
        stdoutSink: io.output,
        stderrSink: io.error,
      );

      expect(runner.effectiveEnvironment, const {'SAFE': 'value'});
    });
  });

  group('WindowsBatchPolicy.isBatchScript', () {
    test('matches only batch extensions case-insensitively', () {
      for (final name in ['dart.bat', r'C:\sdk\dart.CMD', 'flutter.Bat']) {
        expect(WindowsBatchPolicy.isBatchScript(name), isTrue);
      }
      for (final name in ['dart', 'dart.exe', 'bat', 'dart.bat.txt']) {
        expect(WindowsBatchPolicy.isBatchScript(name), isFalse);
      }
    });
  });

  group('windowsBatchArguments', () {
    test('caret-escapes percent in unquoted arguments', () {
      expect(
        WindowsBatchPolicy.arguments([
          'run',
          '-DXCROSS_VERSION=feature%2Fa%2Cb%3Dc',
          '%PATH%',
        ]),
        ['run', '-DXCROSS_VERSION=feature^%2Fa^%2Cb^%3Dc', '^%PATH^%'],
      );
    });

    test('leaves quoted arguments without percent unchanged', () {
      expect(WindowsBatchPolicy.arguments([r'C:\Program Files\a & b']), [
        r'C:\Program Files\a & b',
      ]);
    });

    test('allows quoted arguments when the script path has no whitespace', () {
      expect(
        WindowsBatchPolicy.arguments([
          'a b',
          '',
        ], executable: r'C:\sdk\bin\dart.bat'),
        ['a b', ''],
      );
    });

    test('rejects quoted arguments when the script path is quoted', () {
      for (final argument in ['a b', '']) {
        expect(
          () => WindowsBatchPolicy.arguments([
            argument,
          ], executable: r'C:\Program Files\sdk\dart.bat'),
          throwsA(isA<CliError>()),
        );
      }
      expect(
        WindowsBatchPolicy.arguments([
          'pub',
          'get',
        ], executable: r'C:\Program Files\sdk\dart.bat'),
        ['pub', 'get'],
      );
    });

    for (final executable in [
      r'C:\sdk&tools\dart.bat',
      r'C:\sdk|tools\dart.bat',
      r'C:\sdk^tools\dart.bat',
      r'C:\%SDK%\dart.bat',
      r'C:\Program Files\%SDK%\dart.bat',
      r'C:\sdk"tools\dart.bat',
    ]) {
      test('rejects the script path ${jsonEncode(executable)}', () {
        expect(
          () => WindowsBatchPolicy.arguments(const [
            'pub',
          ], executable: executable),
          throwsA(
            isA<CliError>().having(
              (error) => error.message,
              'message',
              contains(jsonEncode(executable)),
            ),
          ),
        );
      });
    }

    test('rejects a quoted script path that cmd.exe would unquote', () {
      expect(
        () => WindowsBatchPolicy.arguments(const [
          'pub',
        ], executable: r'C:\Program Files (x86)\sdk\dart.bat'),
        throwsA(isA<CliError>()),
      );
      expect(
        WindowsBatchPolicy.arguments(const [
          'pub',
        ], executable: r'C:\sdk(x86)\dart.bat'),
        ['pub'],
      );
    });

    for (final argument in [
      'with space %VAR%',
      'tab\t%VAR%',
      '"%VAR%"',
      'a&b',
      'a|b',
      'a<b',
      'a>b',
      'a^b',
      'a"b',
      '"quoted"',
      '"a&b"',
      'line\nbreak',
      'line\rbreak',
    ]) {
      test('rejects ${jsonEncode(argument)}', () {
        expect(
          () => WindowsBatchPolicy.arguments([argument]),
          throwsA(
            isA<CliError>().having(
              (error) => error.message,
              'message',
              contains(jsonEncode(argument)),
            ),
          ),
        );
      });
    }
  });

  group('start', () {
    test('starts Windows batch scripts in a plain working directory', () async {
      final directory = Directory.systemTemp.createTempSync('batch-cwd-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final script = File(p.join(directory.path, 'cwd.cmd'))
        ..writeAsStringSync('@echo off\r\necho %CD%\r\n');

      final process = await runner.start(
        script.path,
        const [],
        workingDirectory: directory.path,
      );
      final output = await process.stdout
          .transform(systemEncoding.decoder)
          .join();
      final errors = await process.stderr
          .transform(systemEncoding.decoder)
          .join();

      expect(await process.exitCode, 0);
      expect(errors, isNot(contains('UNC')));
      expect(
        output.trim().toLowerCase(),
        directory.resolveSymbolicLinksSync().toLowerCase(),
      );
    }, skip: !Platform.isWindows);

    test(
      'forwards escaped and quoted arguments through a Windows batch script',
      () async {
        final directory = Directory.systemTemp.createTempSync('batch-start-');
        addTearDown(() => directory.deleteSync(recursive: true));
        final script = File(p.join(directory.path, 'emit.cmd'))
          ..writeAsStringSync('@echo off\r\necho %1\r\necho %2\r\n');

        final process = await runner.start(
          script.path,
          const ['feature%2Fa%2Cb', r'C:\Program Files\a & b'],
          environment: const {'2Fa': 'EXPANDED'},
        );
        final output = await process.stdout
            .transform(systemEncoding.decoder)
            .join();

        expect(await process.exitCode, 0);
        expect(const LineSplitter().convert(output.trim()), [
          'feature%2Fa%2Cb',
          r'"C:\Program Files\a & b"',
        ]);
      },
      skip: !Platform.isWindows,
    );

    test(
      'merges configured child environment without inheriting parent',
      () async {
        runner = ProcessRunner(
          nativeHost,
          log: log,
          configuration: ProcessConfiguration(
            normalizedTools: const {},
            effectiveChildEnvironment: const {'START_VALUE': 'configured'},
          ),
          stdinStream: io.input,
          stdoutSink: io.output,
          stderrSink: io.error,
        );

        final directory = Directory.systemTemp.createTempSync('process-start-');
        addTearDown(() => directory.deleteSync(recursive: true));
        final script = File(p.join(directory.path, 'environment.dart'))
          ..writeAsStringSync(
            "import 'dart:io'; void main() { "
            "stdout.write(Platform.environment['START_VALUE']); }",
          );
        final process = await runner.start(Platform.resolvedExecutable, [
          script.path,
        ]);
        final output = await process.stdout
            .transform(systemEncoding.decoder)
            .join();

        expect(await process.exitCode, 0);
        expect(output, 'configured');
      },
    );
  });

  group('batch scripts through every launcher', () {
    const encoded = 'feature%2Fa%2Cb';
    const environment = {'2Fa': 'EXPANDED'};
    late String script;
    late String output;

    setUp(() {
      final directory = Directory.systemTemp.createTempSync('batch-paths-');
      addTearDown(() => directory.deleteSync(recursive: true));
      output = p.join(directory.path, 'out.txt');
      script =
          (File(p.join(directory.path, 'emit.bat'))..writeAsStringSync(
                '@echo off\r\necho %1\r\necho %1> "$output"\r\n',
              ))
              .path;
    });

    String written() => File(output).readAsStringSync().trim();

    test('run', () async {
      final result = await runner.run(script, const [
        encoded,
      ], environment: environment);
      expect(result.exitCode, 0);
      expect(result.stdout.trim(), encoded);
    });

    test('run with a timeout', () async {
      final result = await runner.run(
        script,
        const [encoded],
        environment: environment,
        timeout: const Duration(minutes: 1),
      );
      expect(result.exitCode, 0);
      expect(result.stdout.trim(), encoded);
    });

    for (final (name, call) in <(String, Future<void> Function(String))>[
      (
        'runChecked',
        (script) => runner.runChecked(script, const [
          encoded,
        ], environment: environment),
      ),
      (
        'runChecked inheritStdio',
        (script) => runner.runChecked(
          script,
          const [encoded],
          environment: environment,
          inheritStdio: true,
        ),
      ),
      (
        'runChecked captureAndEcho',
        (script) => runner.runChecked(
          script,
          const [encoded],
          environment: environment,
          captureAndEcho: true,
        ),
      ),
      (
        'runChecked tail',
        (script) => log.logStep(
          'batch',
          () => runner.runChecked(
            script,
            const [encoded],
            environment: environment,
            tail: log.activeStep,
            forwardStdin: false,
          ),
        ),
      ),
    ]) {
      test(name, () async {
        await call(script);
        expect(written(), encoded);
      });
    }

    test('runChecked rejects an argument cmd.exe would alter', () async {
      await expectLater(
        runner.runChecked(script, const ['a&b']),
        throwsA(isA<CliError>()),
      );
      expect(File(output).existsSync(), isFalse);
    });
  }, skip: !Platform.isWindows);

  group('run', () {
    test('replaces differently cased Windows environment overrides', () async {
      if (!Platform.isWindows) return;
      final directory = Directory.systemTemp.createTempSync('process-path-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final script = File(p.join(directory.path, 'environment.dart'))
        ..writeAsStringSync(
          "import 'dart:io'; void main() { "
          'final paths = Platform.environment.entries.where((e) => '
          "e.key.toUpperCase() == 'PATH').toList(); "
          r"stdout.write('${paths.length}|${paths.single.value}'); }",
        );
      runner = ProcessRunner(
        nativeHost,
        log: log,
        configuration: ProcessConfiguration(
          normalizedTools: const {},
          effectiveChildEnvironment: const {'Path': 'configured'},
        ),
        stdinStream: io.input,
        stdoutSink: io.output,
        stderrSink: io.error,
      );

      final result = await runner.run(
        Platform.resolvedExecutable,
        [script.path],
        environment: const {'PATH': 'local'},
      );

      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, '1|local');
    });

    test(
      'captures stdout/stderr and the exit code of a real process',
      () async {
        final result = await runner.run(Platform.resolvedExecutable, [
          '--version',
        ]);
        expect(result.exitCode, 0);
        expect(result.stdout + result.stderr, contains('Dart'));
      },
    );

    test(
      'merges configured child environment with local values winning',
      () async {
        final directory = Directory.systemTemp.createTempSync('process-env-');
        addTearDown(() => directory.deleteSync(recursive: true));
        final script = File(p.join(directory.path, 'environment.dart'))
          ..writeAsStringSync(
            "import 'dart:io'; void main() { stdout.write([ "
            "Platform.environment['BASE'], "
            "Platform.environment['OVERRIDE'], "
            "Platform.environment['LOCAL']].join('|')); }",
          );
        runner = ProcessRunner(
          nativeHost,
          log: log,
          configuration: ProcessConfiguration(
            normalizedTools: const {},
            effectiveChildEnvironment: const {
              'BASE': 'configured',
              'OVERRIDE': 'configured',
            },
          ),
          stdinStream: io.input,
          stdoutSink: io.output,
          stderrSink: io.error,
        );

        final result = await runner.run(
          Platform.resolvedExecutable,
          [script.path],
          environment: const {'OVERRIDE': 'local', 'LOCAL': 'present'},
        );

        expect(result.exitCode, 0);
        expect(result.stdout, 'configured|local|present');
      },
    );

    test('replaces malformed UTF-8 from a successful process', () async {
      final directory = Directory.systemTemp.createTempSync('process-output-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final script = File(p.join(directory.path, 'output.dart'))
        ..writeAsStringSync(
          "import 'dart:io'; void main() { stdout.add([255]); }",
        );

      final result = await runner.run(Platform.resolvedExecutable, [
        script.path,
      ]);

      expect(result.exitCode, 0);
      expect(result.stdout, '\u{fffd}');
    });
  });

  group('runChecked', () {
    test('retains diagnostics when echoing subprocess output', () async {
      final directory = Directory.systemTemp.createTempSync('xcross-echo-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final script = File(p.join(directory.path, 'fail.dart'))
        ..writeAsStringSync(
          "import 'dart:io'; void main() { stderr.writeln('missing-Swift.h file not found'); exit(1); }",
        );
      await expectLater(
        runner.runChecked(Platform.resolvedExecutable, [
          script.path,
        ], captureAndEcho: true),
        throwsA(
          isA<CliError>().having(
            (error) => error.message,
            'message',
            contains('missing-Swift.h file not found'),
          ),
        ),
      );
    });

    test(
      'throws CliError with the command line embedded on a non-zero exit',
      () async {
        await expectLater(
          runner.runChecked(Platform.resolvedExecutable, [
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
        await posixRunner().whichAll(
          'ld64.lld',
          environment: const {'PATH': ''},
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
          await posixRunner().whichAll(
            'ld64.lld',
            environment: {'PATH': tmp.path},
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
        await runner.whichAll(
          'ld64.lld',
          environment: {'PATH': onPath.path},
          extraDirectories: [extra.path],
        ),
        [p.join(onPath.path, 'ld64.lld'), p.join(extra.path, 'ld64.lld')],
      );
    });
  });

  group('describeExitCode', () {
    test('names a Windows NTSTATUS reported as a raw DWORD', () {
      expect(
        windowsRunner().describeExitCode(0xC0000135),
        contains('STATUS_DLL_NOT_FOUND'),
      );
    });

    test('names the same status when dart:io sign-extends it', () {
      expect(
        windowsRunner().describeExitCode(-1073740791),
        allOf(contains('0xC0000409'), contains('abort()')),
      );
    });

    test('still explains an NTSTATUS it has no name for', () {
      expect(
        windowsRunner().describeExitCode(0xC0000123),
        contains('died instead of exiting'),
      );
    });

    test('reads a small negative code as a POSIX signal', () {
      expect(posixRunner().describeExitCode(-11), 'killed by signal 11');
    });

    test('says nothing about an ordinary non-zero exit', () {
      expect(windowsRunner().describeExitCode(1), isNull);
      expect(windowsRunner().describeExitCode(255), isNull);
    });

    test('separates a crash from a chosen exit status', () {
      expect(windowsRunner().crashed(1), isFalse);
      expect(windowsRunner().crashed(255), isFalse);
      expect(posixRunner().crashed(-11), isTrue);
      expect(windowsRunner().crashed(-11), isFalse);
      expect(posixRunner().crashed(0xC0000409), isFalse);
      expect(windowsRunner().crashed(-1073740791), isTrue);
      expect(windowsRunner().crashed(0xC0000409), isTrue);
    });
  });
}
