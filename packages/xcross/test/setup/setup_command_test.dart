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
  }) {
    final command = SetupCommand(
      host: host,
      createHttpClient: () => throw StateError('unexpected HTTP'),
      runner: runner,
      requirements: const WindowsSetupRequirements(),
      scriptPolicy: PosixSetupScript(host),
      swiftInstallGuidance: 'fixture',
      commandPrompt: prompt,
      setupSource: source ?? script.path,
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
  FixturePrompt({this.answer, this.interactive = true});
  final String? answer;
  final bool interactive;
  final asked = <String>[];

  @override
  bool get isInteractive => interactive;
  @override
  void write(String value) {}
  @override
  String? readLine(String prompt) {
    asked.add(prompt);
    return answer;
  }

  @override
  String? readSecret(String prompt, {required String valueName}) =>
      throw StateError('unexpected secret prompt');
}
