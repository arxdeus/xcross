import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/cli/internal/parsed_command.dart';
import 'package:xcross/src/composition/ios_target.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';
import 'package:xcross/src/target/shared/runtime/build_features.dart';

part 'compose_setup_command.g.dart';

typedef ComposeSetupProblems = Future<List<String>> Function();
typedef ComposeSetupEnsure = Future<void> Function({required bool force});
typedef ComposeSetupLogDone = void Function(String message);

@CliOptions()
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

  @CliOption(
    abbr: 'v',
    help: 'Show full toolchain download and warm-up output.',
    negatable: false,
  )
  late bool verbose;
}

final class ComposeSetupCommand<T extends PlatformHostInterface>
    extends ParsedCommand<ComposeSetupArgs, void> {
  @override
  ArgParser populateOptions(ArgParser parser) =>
      _$populateComposeSetupArgsParser(parser);
  @override
  ComposeSetupArgs parseOptions(ArgResults results) =>
      _$parseComposeSetupArgsResult(results);

  ComposeSetupCommand(XcrossRuntime<T> runtime)
    : this._withRuntime(runtime, composePhysicalFeatures(runtime));

  ComposeSetupCommand._withRuntime(
    XcrossRuntime<T> runtime,
    XcrossBuildFeatures<T> features,
  ) : this.withSeams(
        log: runtime.log,
        problems: () => features.composeResolver.problems(
          environment: runtime.runner.effectiveEnvironment,
          projectRoot: runtime.host.paths.context.current,
        ),
        ensure: ({required force}) async {
          await features.composeResolver.ensure(
            environment: runtime.runner.effectiveEnvironment,
            projectRoot: runtime.host.paths.context.current,
            force: force,
          );
        },
        logDone: runtime.log.logDone,
      );

  ComposeSetupCommand.withSeams({
    required this.log,
    required ComposeSetupProblems problems,
    required ComposeSetupEnsure ensure,
    required ComposeSetupLogDone logDone,
  }) : _problems = problems,
       _ensure = ensure,
       _logDone = logDone;

  final Log log;
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
    if (options.verbose) log.setVerbose();
    if (options.check) {
      final problems = await _problems();
      if (problems.isNotEmpty) {
        throw XcrossError(
          'Compose setup check failed:\n${problems.map((p) => '- $p').join('\n')}',
        );
      }
      _logDone('Compose toolchain ready');
      return;
    }
    await _ensure(force: options.force);
    _logDone('Compose toolchain ready');
  }
}
