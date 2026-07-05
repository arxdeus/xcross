import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:xcross/src/build/compose_preflight.dart';
import 'package:xcross/src/build/compose_setup.dart';
import 'package:xcross/src/util/logging.dart';

part 'compose_setup_args.g.dart';

@CliOptions(createCommand: true)
class ComposeSetupArgs {
  const ComposeSetupArgs({
    this.check = false,
    this.force = false,
  });

  @CliOption(
    negatable: false,
    help: 'Only validate the toolchain; do not install anything.',
  )
  final bool check;

  @CliOption(
    negatable: false,
    help: 'Provision even if the toolchain already looks ready.',
  )
  final bool force;
}

/// `xcross compose setup` — download the Kotlin/Native toolchain for
/// `xcross compose` into a user-writable dir (`$HOME/.konan`): the linux-x86_64
/// prebuilt, the ios_arm64 overlay, and the warmed konan deps. Rootless port of
/// setup-compose.sh — xcross never runs sudo/apt.
///
/// System packages (JDK 21, clang, lld) are prerequisites; if any is missing
/// this reports it with an install hint instead of installing it.
///
/// `build`/`run` provision automatically when caches are missing; this command
/// forces provisioning up front (e.g. to pre-warm CI) and reports what's needed.
class ComposeSetupCommand extends _$ComposeSetupArgsCommand<void> {
  @override
  String get name => 'setup';

  @override
  String get description =>
      'Download the Kotlin/Native toolchain for `xcross compose` into '
      r'$HOME/.konan (rootless). JDK/clang/lld are prerequisites.';

  @override
  Future<void> run() async {
    final env = Platform.environment;
    final checkOnly = _options.check;
    final force = _options.force;

    if (checkOnly) {
      final problems = collectComposeProblems(env);
      if (problems.isEmpty) {
        logInfo('compose: host toolchain is ready.');
        return;
      }
      // Print the actionable report but do not throw for --check.
      logInfo(formatComposeProblems(problems));
      return;
    }

    if (!force && collectComposeProblems(env).isEmpty) {
      logInfo('compose: host toolchain already ready — nothing to do '
          '(use --force to re-provision).');
      return;
    }

    final toolchain = await provisionComposeToolchain(
      env: env,
      projectRoot: Directory.current.path,
    );
    logInfo('');
    logInfo('compose toolchain ready:');
    logInfo('  JAVA_HOME       = ${toolchain.javaHome ?? '(unset)'}');
    logInfo('  XCROSS_LD64LLD  = ${toolchain.ld64lld ?? '(unset)'}');
    logInfo('  LX_KN           = ${toolchain.lxKn ?? '(unset)'}');
    logInfo('  KONAN_DATA_DIR  = ${toolchain.konanDataDir ?? '(unset)'}');
    logInfo('');
    logInfo('`xcross compose build`/`run` will now use these automatically.');
  }
}
