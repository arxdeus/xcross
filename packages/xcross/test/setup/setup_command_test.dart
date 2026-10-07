import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/shared/setup/posix_setup_script.dart';
import 'package:xcross/src/host/windows/setup/windows_setup_requirements.dart';
import 'package:xcross/src/shared/cli/basic/setup_command.dart';
import 'package:xcross/src/shared/cli/command_prompt.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/setup/setup_script_policy.dart';

import '../host_operations_fixtures.dart';

void main() {
  late Directory temporary;
  late LinuxHost host;
  late ProcessRunner runner;
  late File script;
  late List<Map<String, String>> executions;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('xcross-setup-command-');
    host = LinuxHost(
      environment: {'XDG_CACHE_HOME': temporary.path, 'HOME': temporary.path},
    );
    runner = fixtureRunner(host, log: fixtureLog());
    script = File(p.join(temporary.path, 'apt.sh'))
      ..writeAsStringSync('echo setup');
    executions = [];
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  Future<void> runSetup(
    FixturePrompt prompt, {
    List<String> arguments = const [],
    String? source,
    SetupScriptPolicy? policy,
    bool configured = true,
  }) {
    final command = SetupCommand(
      host: host,
      createHttpClient: () => throw StateError('unexpected HTTP'),
      runner: runner,
      requirements: const WindowsSetupRequirements(),
      scriptPolicy: policy ?? PosixSetupScript(host),
      swiftInstallGuidance: 'fixture',
      commandPrompt: prompt,
      setupSource: configured ? source ?? script.path : null,
      executeScript: (_, _, environment) async => executions.add(environment),
    );
    return (CommandRunner<void>(
      'xcross',
      'test',
    )..addCommand(command)).run(['setup', ...arguments]);
  }

  test('asks with the script name and source before running', () async {
    final prompt = FixturePrompt(answer: 'y');
    await runSetup(prompt);
    expect(prompt.asked.single, contains('apt.sh'));
    expect(prompt.asked.single, contains(script.path));
    expect(executions, [<String, String>{}]);
  });

  test('anything but yes leaves the host untouched', () async {
    for (final answer in ['', 'n', 'no', 'sure', null]) {
      await runSetup(FixturePrompt(answer: answer));
    }
    expect(executions, isEmpty);
  });

  test('refuses to run unconfirmed without a terminal', () async {
    await expectLater(
      runSetup(FixturePrompt(interactive: false)),
      throwsA(
        isA<XcrossError>().having(
          (error) => error.message,
          'message',
          contains('--yes'),
        ),
      ),
    );
    expect(executions, isEmpty);
  });

  test('--yes skips the prompt and tells the script', () async {
    final prompt = FixturePrompt(interactive: false);
    await runSetup(prompt, arguments: ['--yes']);
    expect(prompt.asked, isEmpty);
    expect(executions, [
      {'XCROSS_SETUP_ASSUME_YES': '1'},
    ]);
  });

  test('a missing local script fails before asking', () async {
    final prompt = FixturePrompt(answer: 'y');
    await expectLater(
      runSetup(prompt, source: p.join(temporary.path, 'missing.sh')),
      throwsA(isA<XcrossError>()),
    );
    expect(prompt.asked, isEmpty);
    expect(executions, isEmpty);
  });

  test('logs the SHA-256 of the exact bytes it is about to run', () async {
    final output = CapturedLogOutput();
    runner = fixtureRunner(host, log: Log(output: output));
    await runSetup(FixturePrompt(answer: 'y'));
    final digest = sha256.convert(utf8.encode('echo setup')).toString();
    expect(output.text, contains(digest));
    expect(output.text, contains('apt.sh'));
  });

  group('built-in per-manager scripts', () {
    late FixtureManagerPolicy policy;
    late Map<String, File> scripts;

    setUp(() {
      scripts = {
        for (final manager in ['winget', 'scoop', 'choco', 'direct'])
          manager: File(p.join(temporary.path, '$manager.ps1'))
            ..writeAsStringSync('# $manager'),
      };
      policy = FixtureManagerPolicy(PosixSetupScript(host), scripts);
    });

    String ran(FixturePrompt prompt) =>
        prompt.asked.lastWhere((line) => line.startsWith('Run ')).split(' ')[1];

    test('runs the only installed manager without asking which', () async {
      policy.installed = ['scoop'];
      final prompt = FixturePrompt(answer: 'y');
      await runSetup(prompt, policy: policy, configured: false);
      expect(prompt.asked, hasLength(1));
      expect(ran(prompt), 'scoop.ps1');
    });

    test('falls back to direct.ps1 without any package manager', () async {
      policy.installed = [];
      final prompt = FixturePrompt(answer: 'y');
      await runSetup(prompt, policy: policy, configured: false);
      expect(ran(prompt), 'direct.ps1');
    });

    test('asks which manager when several are installed', () async {
      policy.installed = ['winget', 'choco'];
      final prompt = FixturePrompt(answers: ['7', '2', 'y']);
      await runSetup(prompt, policy: policy, configured: false);
      expect(prompt.asked.first, startsWith('Which one'));
      expect(prompt.written.join(), contains('[2] choco'));
      expect(prompt.written.join(), contains('Invalid choice "7"'));
      expect(ran(prompt), 'choco.ps1');
    });

    test('--manager picks one explicitly, including direct', () async {
      policy.installed = ['winget', 'scoop'];
      final prompt = FixturePrompt(answer: 'y');
      await runSetup(
        prompt,
        policy: policy,
        configured: false,
        arguments: ['--manager', 'direct'],
      );
      expect(ran(prompt), 'direct.ps1');
    });

    test('--manager rejects a manager that is not installed', () async {
      policy.installed = ['winget'];
      await expectLater(
        runSetup(
          FixturePrompt(answer: 'y'),
          policy: policy,
          configured: false,
          arguments: ['--manager', 'choco'],
        ),
        throwsA(isA<XcrossError>()),
      );
      expect(executions, isEmpty);
    });

    test('a configured setup: script wins over the built-in ones', () async {
      policy.installed = ['winget'];
      final prompt = FixturePrompt(answer: 'y');
      await runSetup(prompt, policy: policy);
      expect(ran(prompt), 'apt.sh');
    });
  });
}

@internal
final class CapturedLogOutput implements LogOutput {
  final _buffer = StringBuffer();
  String get text => '$_buffer';
  @override
  bool get supportsAnsi => false;
  @override
  int get terminalColumns => 200;
  @override
  void stdout(String message) => _buffer.writeln(message);
  @override
  void stderr(String message) => _buffer.writeln(message);
  @override
  void write(String message) => _buffer.write(message);
}

@internal
final class FixturePrompt implements CommandPrompt {
  FixturePrompt({this.answer, List<String>? answers, this.interactive = true})
    : _answers = answers;
  final String? answer;
  final List<String>? _answers;
  final bool interactive;
  final asked = <String>[];
  final written = <String>[];

  @override
  bool get isInteractive => interactive;
  @override
  void write(String value) => written.add(value);
  @override
  String? readLine(String prompt) {
    asked.add(prompt);
    final queued = _answers;
    return queued == null ? answer : queued.removeAt(0);
  }

  @override
  String? readSecret(String prompt, {required String valueName}) =>
      throw StateError('unexpected secret prompt');
}

@internal
final class FixtureManagerPolicy implements SetupScriptPolicy {
  FixtureManagerPolicy(this.base, this.scripts);
  final SetupScriptPolicy base;
  final Map<String, File> scripts;
  List<String> installed = const [];

  DefaultSetupScript _script(String manager) =>
      (manager: manager, source: scripts[manager]!.path);

  @override
  Future<List<DefaultSetupScript>> defaultSources() async => installed.isEmpty
      ? [_script('direct')]
      : [for (final manager in installed) _script(manager)];
  @override
  Future<DefaultSetupScript?> sourceFor(String manager) async =>
      manager == 'direct' || installed.contains(manager)
      ? _script(manager)
      : null;
  @override
  List<String> get supportedManagers => ['winget', 'scoop', 'choco', 'direct'];
  @override
  File cachedFile(String digest) => base.cachedFile(digest);
  @override
  File cachePointer(String digest) => base.cachePointer(digest);
  @override
  Future<({String executable, List<String> arguments})> invocation(
    String path,
  ) => base.invocation(path);
  @override
  void replace(File temporary, File destination) =>
      base.replace(temporary, destination);
}
