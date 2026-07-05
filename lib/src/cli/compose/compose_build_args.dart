import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:xcross/src/cli/compose/compose_operations.dart';
import 'package:xcross/src/cli/shared/ipa_packager.dart';
import 'package:xcross/src/models/compose/compose_options.dart';
import 'package:xcross/src/util/logging.dart';

part 'compose_build_args.g.dart';

@CliOptions(createCommand: true)
class ComposeBuildArgs {
  const ComposeBuildArgs({
    this.configuration = ComposeConfiguration.release,
    this.sign = false,
    this.codesign = false,
    this.ipa = false,
  });

  @CliOption(
    abbr: 'c',
    defaultsTo: ComposeConfiguration.release,
    help: 'Build configuration (release default).',
  )
  final ComposeConfiguration configuration;

  @CliOption(
    abbr: 's',
    negatable: false,
    help: 'Codesign the built app (delegates to `xtool install`).',
  )
  final bool sign;

  @CliOption(help: 'Alias of --sign (flutter-style).')
  final bool codesign;

  @CliOption(
    abbr: 'i',
    negatable: false,
    help: 'Output a .ipa archive instead of a bare .app.',
  )
  final bool ipa;
}

/// `xcross compose build` — build a Kotlin Multiplatform iOS `.app`.
///
/// Defaults to release configuration; pass `-c debug` for a debug build.
/// Mirrors ComposeBuildCommand from ComposeCommand.swift.
class ComposeBuildCommand extends _$ComposeBuildArgsCommand<void> {
  @override
  String get name => 'build';

  @override
  String get description =>
      'Build a Kotlin (Compose) Multiplatform iOS app using xtool.';

  bool get _sign => _options.sign || _options.codesign;

  @override
  Future<void> run() async {
    final options = ComposeOptions(
      configuration: _options.configuration,
      sign: _sign,
      ipa: _options.ipa,
    );

    final result = await composePack(options: options);

    if (_sign) {
      // xtool has no standalone sign command; signing happens at install time.
      logWarn(
        'xcross delegates signing to `xtool install` (xtool has no standalone '
        'sign command). Produced an unsigned .app; use `xcross compose run` or '
        '`xtool install <app>` to sign + install.',
      );
    }

    final finalPath =
        options.ipa ? await packageIpa(result.appPath) : result.appPath;
    logInfo('Wrote to $finalPath');
  }
}
