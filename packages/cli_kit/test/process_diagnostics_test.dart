import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/shared/errors/errors.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:cli_kit/shared/process/tool_lookup.dart';
import 'package:meta/meta.dart';
import 'package:test/test.dart';

import 'support/test_log_output.dart';
import 'support/test_process_io.dart';

@internal
final class DiagnosticHost implements PlatformHostInterface {
  DiagnosticHost(this.base, this.processes);
  final PlatformHostInterface base;
  @override
  final HostProcessInterface processes;
  @override
  String get name => base.name;
  @override
  String get architecture => base.architecture;
  @override
  HostPathsInterface get paths => base.paths;
  @override
  HostEnvironmentInterface get environment => base.environment;
  @override
  HostFileSystemInterface get fileSystem => base.fileSystem;
}

@internal
final class DiagnosticProcesses implements HostProcessInterface {
  DiagnosticProcesses(this.diagnostics, this.code, this.output);
  final HostProcessInterface diagnostics;
  final int code;
  final String output;
  final List<int> described = [];
  final List<DiagnosticChild> children = [];
  final List<Map<String, String>> terminationOverrides = [];

  @override
  ProcessExitDiagnostic describeExit(int exitCode) {
    described.add(exitCode);
    return diagnostics.describeExit(exitCode);
  }

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    final child = DiagnosticChild(code, output);
    children.add(child);
    return child;
  }

  @override
  Future<String?> findOnShellPath(
    String name, {
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) => throw StateError('Unexpected shell lookup');

  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) async => terminationOverrides.add(executableOverrides);
}

@internal
final class DiagnosticChild implements Process {
  DiagnosticChild(int code, String output)
    : exitCode = Future.value(code),
      stdout = Stream.value(utf8.encode(output)) {
    _input.stream.listen((_) {});
  }

  final _input = StreamController<List<int>>();
  @override
  final Future<int> exitCode;
  @override
  final Stream<List<int>> stdout;
  @override
  final Stream<List<int>> stderr = const Stream.empty();
  @override
  late final IOSink stdin = IOSink(_input.sink);
  @override
  int get pid => 101;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      throw StateError('Unexpected child termination');

  Future<void> close() async {
    await stdin.close();
    await _input.close();
  }
}

void main() {
  final windows = WindowsHost();
  final linux = LinuxHost();
  final macos = MacOSHost();

  group('host-selected exit diagnostics', () {
    test('Windows names signed and unsigned NTSTATUS identically', () {
      for (final status in [
        0xC0000005,
        0xC000001D,
        0xC000007B,
        0xC00000FD,
        0xC0000135,
        0xC0000139,
        0xC0000142,
        0xC0000374,
        0xC0000409,
      ]) {
        final unsigned = windows.processes.describeExit(status);
        final signed = windows.processes.describeExit(status - 0x100000000);
        expect(unsigned.crashed, isTrue);
        expect(unsigned.description, contains('STATUS_'));
        expect(signed.crashed, isTrue);
        expect(signed.description, unsigned.description);
      }
    });

    test('Windows bounds status values without interpreting POSIX signals', () {
      for (final code in [
        0,
        1,
        255,
        -1,
        -11,
        -255,
        0xBFFFFFFF,
        0x100000000,
        -0x40000001,
      ]) {
        final diagnostic = windows.processes.describeExit(code);
        expect(diagnostic.crashed, isFalse, reason: '$code');
        expect(diagnostic.description, isNull, reason: '$code');
      }
      for (final code in [-256, -0x40000000, 0xFFFFFFFF, 0xC0000123]) {
        final diagnostic = windows.processes.describeExit(code);
        expect(diagnostic.crashed, isTrue, reason: '$code');
        expect(diagnostic.description, contains('NTSTATUS'), reason: '$code');
      }
    });

    for (final host in [linux, macos]) {
      test('${host.name} owns negative signal interpretation only', () {
        for (final signal in [1, 11, 255]) {
          final diagnostic = host.processes.describeExit(-signal);
          expect(diagnostic.crashed, isTrue);
          expect(diagnostic.description, 'killed by signal $signal');
        }
        for (final code in [0, 1, 255, -256, 0xC0000409, -1073740791]) {
          final diagnostic = host.processes.describeExit(code);
          expect(diagnostic.crashed, isFalse, reason: '$code');
          expect(diagnostic.description, isNull, reason: '$code');
        }
      });
    }
  });

  group('runner diagnostics across execution modes', () {
    for (final fixture in [
      (host: windows, code: 0xC0000135, description: 'STATUS_DLL_NOT_FOUND'),
      (host: linux, code: -11, description: 'killed by signal 11'),
      (host: macos, code: -11, description: 'killed by signal 11'),
      (host: windows, code: -11, description: null),
      (host: linux, code: 0xC0000135, description: null),
      (host: linux, code: 1, description: null),
    ]) {
      for (final mode in ['captured', 'inherited', 'streaming', 'tail']) {
        for (final output in ['', 'fixture output']) {
          test(
            '${fixture.host.name} ${fixture.code} $mode output=${output.isNotEmpty}',
            () async {
              final io = TestProcessIo();
              addTearDown(io.close);
              final log = Log(output: TestLogOutput(emit: (_) {}));
              addTearDown(log.stopStep);
              final processes = DiagnosticProcesses(
                fixture.host.processes,
                fixture.code,
                output,
              );
              addTearDown(() async {
                for (final child in processes.children) {
                  await child.close();
                }
              });
              final runner = ProcessRunner(
                DiagnosticHost(fixture.host, processes),
                log: log,
                stdinStream: io.input,
                stdoutSink: io.output,
                stderrSink: io.error,
              );
              await expectLater(
                runner.runChecked(
                  'fixture',
                  ['some argument'],
                  inheritStdio: mode == 'inherited',
                  captureAndEcho: mode == 'streaming',
                  tail: mode == 'tail' ? log.beginStep('fixture') : null,
                  forwardStdin: false,
                ),
                throwsA(
                  isA<CliError>().having(
                    (error) => error.toString(),
                    'diagnostic',
                    predicate<String>((message) {
                      expect(
                        message,
                        contains('command failed (${fixture.code}'),
                      );
                      expect(message, contains('fixture "some argument"'));
                      final description = fixture.description;
                      if (description != null) {
                        expect(message, contains(description));
                      } else {
                        expect(message, isNot(contains('STATUS_')));
                        expect(message, isNot(contains('killed by signal')));
                      }
                      final hint =
                          description != null &&
                          output.isEmpty &&
                          mode != 'inherited';
                      expect(
                        message.contains('It wrote nothing before dying'),
                        hint,
                      );
                      if (output.isNotEmpty && mode != 'inherited') {
                        expect(message, contains(output));
                      }
                      return true;
                    }),
                  ),
                ),
              );
              expect(processes.described, [fixture.code]);
              expect(processes.terminationOverrides, isEmpty);
            },
          );
        }
      }
    }
  });

  group('selected tool-name policy', () {
    for (final host in [windows, linux, macos]) {
      test(
        '${host.name} uses the same configured key policy for cleanup',
        () async {
          final io = TestProcessIo();
          addTearDown(io.close);
          final processes = DiagnosticProcesses(host.processes, 0, '');
          final runner = ProcessRunner(
            DiagnosticHost(host, processes),
            log: Log(output: TestLogOutput(emit: (_) {})),
            stdinStream: io.input,
            stdoutSink: io.output,
            stderrSink: io.error,
            configuration: ProcessConfiguration(
              normalizedTools: const {'TASKKILL.EXE': '/configured/terminate'},
              effectiveChildEnvironment: const {},
            ),
          );
          final child = DiagnosticChild(0, '');
          addTearDown(child.close);
          await runner.killTree(child);
          expect(processes.terminationOverrides, [
            {host.paths.toolNameKey('TASKKILL.EXE'): '/configured/terminate'},
          ]);
        },
      );
    }

    test(
      'Windows canonicalizes all executable suffixes and configured keys',
      () async {
        final tools = ProcessToolLookup(
          windows,
          configuration: ProcessConfiguration(
            normalizedTools: const {' CLANG.EXE ': 'C:/selected/clang.exe'},
            effectiveChildEnvironment: const {
              'PATH': '',
              'PATHEXT': '.EXE;.BAT;.CMD;.COM',
            },
          ),
        );
        for (final name in [
          'clang',
          'CLANG.EXE',
          'clang.bat',
          'Clang.Cmd',
          'clang.COM',
        ]) {
          expect(tools.resolveExecutable(name), 'C:/selected/clang.exe');
          expect(await tools.which(name), 'C:/selected/clang.exe');
        }
      },
    );

    for (final host in [linux, macos]) {
      test(
        '${host.name} preserves distinct literal case and suffix names',
        () async {
          final tools = ProcessToolLookup(
            host,
            configuration: ProcessConfiguration(
              normalizedTools: const {
                'clang': '/selected/clang',
                ' CLANG.EXE ': '/selected/literal',
              },
              effectiveChildEnvironment: const {'PATH': ''},
            ),
          );
          expect(tools.resolveExecutable('clang'), '/selected/clang');
          expect(tools.resolveExecutable('CLANG.EXE'), '/selected/literal');
          expect(await tools.which('CLANG.EXE'), '/selected/literal');
          for (final name in ['clang.exe', 'CLANG', 'clang.bat']) {
            expect(tools.resolveExecutable(name), name);
            expect(await tools.which(name), isNull);
          }
        },
      );
    }

    test(
      'Windows rejects ambiguous aliases instead of order-dependent selection',
      () {
        expect(
          () => ProcessToolLookup(
            windows,
            configuration: ProcessConfiguration(
              normalizedTools: const {
                'clang': '/first',
                'CLANG.EXE': '/second',
              },
              effectiveChildEnvironment: const {},
            ),
          ),
          throwsArgumentError,
        );
      },
    );
  });
}
