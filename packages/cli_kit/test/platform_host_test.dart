import 'dart:async';
import 'dart:io';

import 'package:cli_kit/composition/native_host.dart';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/shared/posix_privileges.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/host/windows/windows_privileges.dart';
import 'package:cli_kit/shared/errors/errors.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_executor.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:cli_kit/shared/process/tool_lookup.dart';
import 'package:cli_kit/src/host/shared/posix_processes.dart';
import 'package:cli_kit/src/host/windows/windows_file_system.dart';
import 'package:cli_kit/src/host/windows/windows_processes.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/test_log_output.dart';
import 'support/test_process_io.dart';

@internal
final class RecordingProcesses implements HostProcessInterface {
  @override
  ProcessExitDiagnostic describeExit(int exitCode) =>
      delegate.describeExit(exitCode);

  RecordingProcesses(this.delegate);
  final HostProcessInterface delegate;
  Map<String, String>? lastEnvironment;
  bool? inherited;

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    lastEnvironment = environment;
    inherited = includeParentEnvironment;
    return delegate.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      mode: mode,
    );
  }

  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) => delegate.killTree(
    process,
    environment: environment,
    executableOverrides: executableOverrides,
  );

  @override
  Future<String?> findOnShellPath(
    String name, {
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) => delegate.findOnShellPath(
    name,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
  );
}

@internal
final class UnownedTestProcess implements Process {
  bool killed = false;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unowned identities cannot be inspected');
}

void main() {
  final io = TestProcessIo();
  tearDownAll(io.close);
  final log = Log(output: TestLogOutput(emit: print));
  final snapshot = detectPlatformHostSnapshot();
  final native = snapshot.host;

  test('host constructors retain unknown architecture without guessing', () {
    expect(WindowsHost().architecture, 'unknown');
    expect(LinuxHost().architecture, 'unknown');
    expect(MacOSHost().architecture, 'unknown');
    expect(native.architecture, isNot('unknown'));
    expect(snapshot.resolvedExecutable, Platform.resolvedExecutable);
    expect(snapshot.localHostname, isNotEmpty);
    expect(snapshot.localeName, isNotEmpty);
    expect(snapshot.processorCount, Platform.numberOfProcessors);
    expect(snapshot.processorCount, greaterThan(0));
    expect(WindowsHost(architecture: 'x64').architecture, 'x64');
  });

  test('host environment snapshots are immutable and isolated', () {
    final source = {'HOME': '/before'};
    final linux = LinuxHost(environment: source);
    final macos = MacOSHost(environment: source);
    final windows = WindowsHost(environment: source);
    source['HOME'] = '/after';
    for (final host in <PlatformHostInterface>[linux, macos, windows]) {
      expect(host.environment.values['HOME'], '/before');
      expect(
        () => host.environment.values['HOME'] = '/changed',
        throwsUnsupportedError,
      );
    }
  });

  test('POSIX environment keys stay case-sensitive', () {
    final environment = LinuxHost().environment;
    expect(environment.lookup({'Path': 'lower'}, 'PATH'), isNull);
    expect(environment.overlay({'Path': 'lower'}, {'PATH': 'upper'}), {
      'Path': 'lower',
      'PATH': 'upper',
    });
    expect(environment.splitPathList('/one:/two'), ['/one', '/two']);
    expect(environment.joinPathList(['/one', '/two']), '/one:/two');
  });

  test('Windows environment overlays collapse spelling differences', () {
    final environment = WindowsHost().environment;
    expect(environment.lookup({'Path': 'value'}, 'path'), 'value');
    expect(environment.overlay({'Path': 'base'}, {'PATH': 'local'}), {
      'PATH': 'local',
    });
    expect(environment.splitPathList(r'C:\one;D:\two'), [r'C:\one', r'D:\two']);
    expect(environment.joinPathList([r'C:\one', r'D:\two']), r'C:\one;D:\two');
    expect(
      environment.executableCandidates('ld64.lld', {'Pathext': '.EXE;cmd'}),
      ['ld64.lld', 'ld64.lld.EXE', 'ld64.lld.cmd'],
    );
    expect(environment.executableCandidates('dart.EXE', {'PATHEXT': '.exe'}), [
      'dart.EXE',
    ]);
  });

  test('POSIX roots preserve existing XDG and home fallbacks', () {
    for (final host in <PlatformHostInterface>[
      LinuxHost(
        environment: const {
          'HOME': '/home',
          'XDG_CONFIG_HOME': '/config',
          'XDG_CACHE_HOME': '/cache',
        },
      ),
      MacOSHost(
        environment: const {
          'HOME': '/home',
          'XDG_CONFIG_HOME': '/config',
          'XDG_CACHE_HOME': '/cache',
        },
      ),
    ]) {
      expect(host.paths.configRoot, '/config');
      expect(host.paths.cacheRoot, '/cache');
    }
    final host = LinuxHost(
      environment: const {
        'HOME': '/home',
        'XDG_CONFIG_HOME': '',
        'XDG_CACHE_HOME': '',
      },
    );
    expect(host.paths.configRoot, '/home/.config');
    expect(host.paths.cacheRoot, '/home/.cache');
  });

  test('Windows roots use case-insensitive appdata and native paths', () {
    final host = WindowsHost(
      environment: const {
        'AppData': r'C:\config',
        'LocalAppData': r'C:\cache',
        'UserProfile': r'C:\home',
      },
      currentDirectory: r'C:\work',
      temporaryDirectory: r'C:\temp',
    );
    expect(host.paths.configRoot, r'C:\config');
    expect(host.paths.cacheRoot, r'C:\cache');
    expect(host.paths.temporaryRoot, r'C:\temp');
    expect(host.paths.ioPath(r'relative\file'), r'\\?\C:\work\relative\file');
    expect(host.paths.pathKey(r'C:\WORK\x'), host.paths.pathKey(r'c:\work\x'));
    expect(
      host.paths.executableName('flutter', extension: '.bat'),
      'flutter.bat',
    );
    expect(
      host.paths.executableName('dart.exe', extension: '.bat'),
      'dart.exe',
    );
    expect(host.paths.executableName('ld64.lld'), 'ld64.lld.exe');
    expect(host.paths.executableName('flutter.CMD'), 'flutter.CMD');
    expect(
      host.paths.executableName('custom.dll', extension: '.dll'),
      'custom.dll',
    );
    expect(
      LinuxHost().paths.executableName('flutter', extension: '.bat'),
      'flutter',
    );
  });

  test(
    'separate runners retain independent configuration and nested copies',
    () async {
      final directories = <String, List<String>>{
        'llvm': ['/before'],
      };
      final configuration = ProcessConfiguration(
        normalizedTools: const {'clang': '/first/clang'},
        effectiveChildEnvironment: const {'FIRST': '1'},
        toolchainDirectories: directories,
      );
      directories['llvm']!.add('/after');
      final first = ProcessRunner(
        native,
        log: log,
        configuration: configuration,
        stdinStream: io.input,
        stdoutSink: io.output,
        stderrSink: io.error,
      );
      final second = ProcessRunner(
        native,
        log: log,
        configuration: ProcessConfiguration(
          normalizedTools: const {'clang': '/second/clang'},
          effectiveChildEnvironment: const {'SECOND': '2'},
        ),
        stdinStream: io.input,
        stdoutSink: io.output,
        stderrSink: io.error,
      );
      expect(await first.which('clang'), '/first/clang');
      expect(await second.which('clang'), '/second/clang');
      expect(first.effectiveEnvironment, const {'FIRST': '1'});
      expect(second.effectiveEnvironment, const {'SECOND': '2'});
      expect(configuration.toolchainDirectories['llvm'], ['/before']);
      expect(
        () => configuration.toolchainDirectories['llvm']!.add('/changed'),
        throwsUnsupportedError,
      );
    },
  );

  test('unconfigured runner launches from the injected host snapshot', () async {
    final temporary = native.fileSystem
        .directory(native.paths.temporaryRoot)
        .createTempSync('host-environment-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final script = File(p.join(temporary.path, 'environment.dart'))
      ..writeAsStringSync(
        "import 'dart:io'; void main() { stdout.write(Platform.environment['CHILD_VALUE']); }",
      );
    final processes = RecordingProcesses(native.processes);
    final host = LinuxHost(
      environment: const {'CHILD_VALUE': 'snapshot'},
      paths: native.paths,
      fileSystem: native.fileSystem,
      processes: processes,
    );
    final runner = ProcessRunner(
      host,
      log: log,
      stdinStream: io.input,
      stdoutSink: io.output,
      stderrSink: io.error,
    );
    final result = await runner.run(
      Platform.resolvedExecutable,
      [script.path],
      environment: const {'LOCAL': 'yes'},
    );
    expect(result.exitCode, 0, reason: result.stderr);
    expect(result.stdout, 'snapshot');
    expect(processes.lastEnvironment, {
      'CHILD_VALUE': 'snapshot',
      'LOCAL': 'yes',
    });
    expect(processes.inherited, isFalse);
  });

  test(
    'configured Windows child overlay is case-insensitive on every test host',
    () async {
      final processes = RecordingProcesses(native.processes);
      final host = WindowsHost(
        environment: const {'HOST_ONLY': 'hidden'},
        paths: native.paths,
        fileSystem: native.fileSystem,
        processes: processes,
      );
      final runner = ProcessRunner(
        host,
        log: log,
        configuration: ProcessConfiguration(
          normalizedTools: const {},
          effectiveChildEnvironment: const {'Path': 'base', 'BASE': 'yes'},
        ),
        stdinStream: io.input,
        stdoutSink: io.output,
        stderrSink: io.error,
      );
      await runner.run(
        Platform.resolvedExecutable,
        const ['--version'],
        environment: const {'PATH': 'local'},
      );
      expect(processes.lastEnvironment, {'PATH': 'local', 'BASE': 'yes'});
      expect(processes.inherited, isFalse);
      expect(runner.effectiveEnvironment, {'Path': 'base', 'BASE': 'yes'});
    },
  );

  test('Windows administrator caches belong to privilege instances', () async {
    var allowedCalls = 0;
    var deniedCalls = 0;
    final runner = ProcessRunner(
      WindowsHost(),
      log: log,
      stdinStream: io.input,
      stdoutSink: io.output,
      stderrSink: io.error,
    );
    final allowed = WindowsPrivileges(
      runner,
      administratorProbe: () async {
        allowedCalls++;
        return const CapturedProcess(0, 'true', '');
      },
    );
    final denied = WindowsPrivileges(
      runner,
      administratorProbe: () async {
        deniedCalls++;
        return const CapturedProcess(0, 'false', '');
      },
    );
    await allowed.ensureElevated();
    await allowed.ensureElevated();
    await expectLater(
      denied.ensureElevated(deniedMessage: 'explicit denial'),
      throwsA(
        isA<CliError>().having(
          (error) => error.message,
          'message',
          'explicit denial',
        ),
      ),
    );
    expect(allowedCalls, 1);
    expect(deniedCalls, 1);
    expect(await denied.resolve(), isNull);
  });

  test('unreadable Windows administrator probe is denied safely', () async {
    final privileges = WindowsPrivileges(
      ProcessRunner(
        WindowsHost(),
        log: log,
        stdinStream: io.input,
        stdoutSink: io.output,
        stderrSink: io.error,
      ),
      administratorProbe: () async => throw StateError('unavailable'),
    );
    await expectLater(privileges.ensureElevated(), throwsA(isA<CliError>()));
  });

  test(
    'Windows credential caching remains a no-op without probing elevation',
    () async {
      var probes = 0;
      final privileges = WindowsPrivileges(
        ProcessRunner(
          WindowsHost(),
          log: log,
          stdinStream: io.input,
          stdoutSink: io.output,
          stderrSink: io.error,
        ),
        administratorProbe: () async {
          probes++;
          return const CapturedProcess(0, 'false', '');
        },
      );
      await privileges.cacheCredentials();
      expect(probes, 0);
    },
  );

  test(
    'POSIX privilege helpers do not launch tools absent from injected PATH',
    () async {
      for (final host in <PlatformHostInterface>[LinuxHost(), MacOSHost()]) {
        final privileges = PosixPrivileges(
          ProcessRunner(
            host,
            log: log,
            stdinStream: io.input,
            stdoutSink: io.output,
            stderrSink: io.error,
          ),
        );
        expect(await privileges.resolve(), isNull);
        await privileges.cacheCredentials();
        await privileges.ensureElevated();
      }
    },
  );

  test(
    'materialized archive links copy files and directories without elevation',
    () async {
      final temporary = native.fileSystem
          .directory(native.paths.temporaryRoot)
          .createTempSync('archive-link-');
      addTearDown(() => temporary.deleteSync(recursive: true));
      final source = File(p.join(temporary.path, 'source'))
        ..writeAsStringSync('content');
      final filesystem = WindowsFileSystem(native.paths);
      final destination = p.join(temporary.path, 'copy');
      await filesystem.createArchiveLink(destination, 'source');
      expect(File(destination).readAsStringSync(), 'content');
      final directory = Directory(p.join(temporary.path, 'directory'))
        ..createSync();
      source.copySync(p.join(directory.path, 'file'));
      await filesystem.createArchiveLink(
        p.join(temporary.path, 'directory-copy'),
        'directory',
      );
      expect(
        File(
          p.join(temporary.path, 'directory-copy', 'file'),
        ).readAsStringSync(),
        'content',
      );
      await expectLater(
        filesystem.createArchiveLink(
          p.join(temporary.path, 'missing-copy'),
          'missing',
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('native cleanup refuses unowned process identities', () async {
    final process = UnownedTestProcess();
    await PosixProcesses(paths: native.paths).killTree(process);
    await WindowsProcesses(
      paths: native.paths,
      environment: native.environment,
      fileSystem: native.fileSystem,
    ).killTree(process);
    expect(process.killed, isFalse);
  });
  test(
    'runner rejects inconsistent host configuration and log collaborators',
    () {
      final first = LinuxHost();
      final second = LinuxHost();
      final config = ProcessConfiguration(
        normalizedTools: const {},
        effectiveChildEnvironment: const {},
      );
      final otherConfig = ProcessConfiguration(
        normalizedTools: const {},
        effectiveChildEnvironment: const {},
      );
      final tools = ProcessToolLookup(first, configuration: config);
      expect(
        () => ProcessExecutor(second, tools: tools, log: log),
        throwsArgumentError,
      );
      expect(
        () => ProcessRunner(
          second,
          log: log,
          configuration: config,
          toolLookup: tools,
          stdinStream: io.input,
          stdoutSink: io.output,
          stderrSink: io.error,
        ),
        throwsArgumentError,
      );
      expect(
        () => ProcessRunner(
          first,
          log: log,
          configuration: otherConfig,
          toolLookup: tools,
          stdinStream: io.input,
          stdoutSink: io.output,
          stderrSink: io.error,
        ),
        throwsArgumentError,
      );
      final executor = ProcessExecutor(first, tools: tools, log: log);
      final runner = ProcessRunner(
        first,
        log: log,
        configuration: config,
        executor: executor,
        stdinStream: io.input,
        stdoutSink: io.output,
        stderrSink: io.error,
      );
      expect(runner.toolLookup, same(tools));
      expect(
        () => ProcessRunner(
          first,
          log: Log(output: TestLogOutput(emit: print)),
          configuration: config,
          executor: executor,
          stdinStream: io.input,
          stdoutSink: io.output,
          stderrSink: io.error,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'archive materialization rejects descendant and canonical alias destinations',
    () async {
      final temp = Directory.systemTemp.createTempSync('archive-cycle-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final source = Directory(p.join(temp.path, 'source'))..createSync();
      final filesystem = WindowsFileSystem(native.paths);
      final descendant = p.join(source.path, 'copy', 'nested');
      await expectLater(
        filesystem.createArchiveLink(descendant, source.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(Directory(p.join(source.path, 'copy')).existsSync(), isFalse);
      await expectLater(
        filesystem.createArchiveLink(source.path, source.path),
        throwsA(isA<FileSystemException>()),
      );
      final alias = Link(p.join(temp.path, 'alias'));
      if (!Platform.isWindows) {
        alias.createSync(source.path);
        await expectLater(
          filesystem.createArchiveLink(p.join(alias.path, 'copy'), source.path),
          throwsA(isA<FileSystemException>()),
        );
        expect(Directory(p.join(source.path, 'copy')).existsSync(), isFalse);
      }
      expect(source.listSync(), isEmpty);
    },
  );

  test(
    'owned Windows cleanup honors configured tool and environment snapshot',
    () async {
      String? invoked;
      Map<String, String>? values;
      bool? inherited;
      var calls = 0;
      final processes = WindowsProcesses(
        paths: native.paths,
        environment: native.environment,
        fileSystem: native.fileSystem,
        runProcess:
            (
              executable,
              arguments, {
              environment,
              includeParentEnvironment = true,
            }) async {
              calls++;
              invoked = executable;
              values = environment;
              inherited = includeParentEnvironment;
              expect(arguments, contains('/PID'));
              return ProcessResult(0, 0, '', '');
            },
      );
      final temp = Directory.systemTemp.createTempSync('owned-cleanup-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final script = File(p.join(temp.path, 'wait.dart'))
        ..writeAsStringSync(
          'Future<void> main() async { await Future<void>.delayed(const Duration(minutes: 10)); }',
        );
      final process = await processes.start(Platform.resolvedExecutable, [
        script.path,
      ]);
      final env = {'PATH': '/configured/path', 'CUSTOM': 'snapshot'};
      await processes.killTree(
        process,
        environment: env,
        executableOverrides: {'taskkill': '/configured/taskkill'},
      );
      await process.exitCode;
      expect(invoked, '/configured/taskkill');
      expect(values, same(env));
      expect(inherited, isFalse);
      await processes.killTree(process, environment: env);
      expect(calls, 1);
    },
  );
}
