@internal
library;

import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/cli/internal/parsed_command.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/ios_gen_snapshot_mode.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';

part 'flutter_precache_command.g.dart';

/// Options for `xcross flutter precache`.
@internal
@CliOptions()
final class FlutterPrecacheArgs {
  @CliOption(
    allowed: ['debug', 'profile', 'release', 'all'],
    defaultsTo: 'all',
    help: 'Which build modes to fetch artifacts for.',
  )
  late String mode;
}

/// Fetches what one build mode needs for the Flutter SDK at a root.
@internal
typedef PrecacheEngine =
    Future<void> Function({
      required String flutterRoot,
      required FlutterBuildMode mode,
    });

/// Fetches the iOS AOT compiler for one precompiled mode, returning where it
/// came from for the report.
@internal
typedef PrecacheCompiler =
    Future<({String executable, String source})> Function({
      required String flutterRoot,
      required IosGenSnapshotMode mode,
    });

/// `xcross flutter precache`: download the iOS engine artifacts and, for
/// profile and release, the iOS AOT compiler for the current Flutter SDK, so
/// CI images and offline machines build without reaching the network.
@internal
final class FlutterPrecacheCommand
    extends ParsedCommand<FlutterPrecacheArgs, void> {
  FlutterPrecacheCommand({
    required this.log,
    required this.resolveFlutterRoot,
    required this.precacheEngine,
    required this.precacheCompiler,
  });

  final Log log;
  final Future<String> Function() resolveFlutterRoot;
  final PrecacheEngine precacheEngine;
  final PrecacheCompiler precacheCompiler;

  @override
  ArgParser populateOptions(ArgParser parser) =>
      _$populateFlutterPrecacheArgsParser(parser);
  @override
  FlutterPrecacheArgs parseOptions(ArgResults results) =>
      _$parseFlutterPrecacheArgsResult(results);

  @override
  String get name => 'precache';

  @override
  String get description =>
      'Download the iOS engine artifacts and AOT compilers the current '
      'Flutter SDK needs, ahead of the first build.';

  @override
  Future<void> run() async {
    final modes = switch (options.mode) {
      'all' => FlutterBuildMode.values,
      final name => [FlutterBuildMode.values.byName(name)],
    };
    final flutterRoot = await resolveFlutterRoot();
    log.logInfo('Flutter SDK', flutterRoot);
    for (final mode in modes) {
      await log.logStep(
        'iOS engine artifacts (${mode.name})',
        () => precacheEngine(flutterRoot: flutterRoot, mode: mode),
      );
      final aotMode = switch (mode) {
        FlutterBuildMode.debug => null,
        FlutterBuildMode.profile => IosGenSnapshotMode.profile,
        FlutterBuildMode.release => IosGenSnapshotMode.release,
      };
      if (aotMode == null) continue;
      final compiler = await precacheCompiler(
        flutterRoot: flutterRoot,
        mode: aotMode,
      );
      log.logDone(
        'iOS AOT compiler (${aotMode.name}): ${compiler.source}',
        compiler.executable,
      );
    }
    log.logDone('Flutter iOS artifacts are cached');
  }
}
