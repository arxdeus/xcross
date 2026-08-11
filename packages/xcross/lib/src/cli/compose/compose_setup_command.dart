import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/compose/toolchain/compose_host.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain_resolver.dart';
import 'package:xcross/src/errors.dart';

part 'compose_setup_command.g.dart';

typedef ComposeSetupProblems = Future<List<String>> Function();
typedef ComposeSetupEnsure = Future<void> Function({required bool force});
typedef ComposeSetupLogDone = void Function(String message);

@CliOptions(createCommand: true)
final class ComposeSetupArgs {
  @CliOption(
    help: 'Check Compose toolchain prerequisites without installing anything.',
    negatable: false,
  )
  late bool check;

  @CliOption(
    help: 'Refresh the Compose Kotlin/Native cache atomically.',
    negatable: false,
  )
  late bool force;
}

final class ComposeSetupCommand extends _$ComposeSetupArgsCommand<void> {
  ComposeSetupCommand()
    : this.withSeams(
        problems: _defaultProblems,
        ensure: _defaultEnsure,
        logDone: Log.logDone,
      );

  ComposeSetupCommand.withSeams({
    required ComposeSetupProblems problems,
    required ComposeSetupEnsure ensure,
    required ComposeSetupLogDone logDone,
  }) : _problems = problems,
       _ensure = ensure,
       _logDone = logDone;

  final ComposeSetupProblems _problems;
  final ComposeSetupEnsure _ensure;
  final ComposeSetupLogDone _logDone;

  @override
  String get name => 'setup';

  @override
  String get description =>
      'Install or check Compose Multiplatform iOS toolchain prerequisites.';

  @override
  Future<void> run() async {
    if (_options.check) {
      final problems = await _problems();
      if (problems.isNotEmpty) {
        throw XcrossError(
          'Compose setup check failed:\n${problems.map((p) => '- $p').join('\n')}',
        );
      }
      _logDone('Compose toolchain ready');
      return;
    }
    await _ensure(force: _options.force);
    _logDone('Compose toolchain ready');
  }

  static Future<List<String>> _defaultProblems() async {
    final host = _currentHostOrProblem();
    if (host.problem != null) return [host.problem!];
    return ComposeToolchainResolver.problems(
      host: host.host!,
      environment: Platform.environment,
      projectRoot: Directory.current.path,
    );
  }

  static Future<void> _defaultEnsure({required bool force}) async {
    final host = _currentHostOrProblem();
    if (host.problem != null) throw XcrossError(host.problem!);
    await ComposeToolchainResolver.ensure(
      host: host.host!,
      environment: Platform.environment,
      projectRoot: Directory.current.path,
      force: force,
    );
  }

  static _HostOrProblem _currentHostOrProblem() {
    try {
      return _HostOrProblem(ComposeHost.current(), null);
    } on XcrossError catch (error) {
      return _HostOrProblem(null, error.message);
    }
  }
}

final class _HostOrProblem {
  const _HostOrProblem(this.host, this.problem);

  final ComposeHost? host;
  final String? problem;
}
