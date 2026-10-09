@internal
library;

import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/cache/cache_pruner.dart';
import 'package:xcross/src/shared/cli/internal/parsed_command.dart';

part 'cache_command.g.dart';

/// `xcross cache`: inspect and trim what xcross downloads.
@internal
final class CacheCommand extends Command<void> {
  CacheCommand(CachePruneCommand prune) {
    addSubcommand(prune);
  }

  @override
  String get name => 'cache';

  @override
  String get description => 'Manage the Flutter caches xcross downloads.';
}

/// Options for `xcross cache prune`.
@internal
@CliOptions()
final class CachePruneArgs {
  @CliOption(
    name: 'dry-run',
    negatable: false,
    help: 'List what would be removed without removing anything.',
  )
  late bool dryRun;

  @CliOption(
    name: 'older-than',
    valueHelp: 'days',
    defaultsTo: '30',
    help:
        'Only remove entries unused for at least this many days. '
        'Entries for a Flutter SDK xcross can find are always kept.',
  )
  late String olderThan;
}

/// `xcross cache prune`: remove Flutter engine artifacts and iOS AOT
/// compilers left behind by Flutter versions no longer in use.
@internal
final class CachePruneCommand extends ParsedCommand<CachePruneArgs, void> {
  CachePruneCommand({
    required this.host,
    required this.log,
    required this.engineRoot,
    required this.genSnapshotRoot,
    required this.inUseEngines,
    DateTime Function()? now,
  }) : _now = now;

  final PlatformHostInterface host;
  final Log log;

  /// Where iOS engine artifacts are cached, per engine revision.
  final String engineRoot;

  /// Where iOS AOT compilers are cached, per engine revision.
  final String genSnapshotRoot;

  /// Engine revisions of every Flutter SDK xcross can discover.
  final Future<Set<String>> Function() inUseEngines;
  final DateTime Function()? _now;

  @override
  ArgParser populateOptions(ArgParser parser) =>
      _$populateCachePruneArgsParser(parser);
  @override
  CachePruneArgs parseOptions(ArgResults results) =>
      _$parseCachePruneArgsResult(results);

  @override
  String get name => 'prune';

  @override
  String get description =>
      'Remove Flutter engine artifacts and iOS AOT compilers for Flutter '
      'versions no longer in use.';

  @override
  Future<void> run() async {
    final args = options;
    final days = int.tryParse(args.olderThan.trim());
    if (days == null || days < 0) {
      usageException('--older-than takes a whole number of days.');
    }
    final engines = await inUseEngines();
    final pruner = CachePruner(
      host,
      engineRoot: engineRoot,
      genSnapshotRoot: genSnapshotRoot,
      inUseEngines: engines,
      olderThan: Duration(days: days),
      now: _now,
    );
    final result = await log.logStep(
      args.dryRun ? 'Scanning the xcross cache' : 'Pruning the xcross cache',
      () => pruner.prune(dryRun: args.dryRun),
    );
    for (final entry in result.removed) {
      log.logStatus(
        '${args.dryRun ? 'Would remove' : 'Removed'} ${entry.kind} '
        '${entry.engine.substring(0, 8)}  ${formatBytes(entry.bytes)}  '
        '${log.dim(entry.path)}',
      );
    }
    if (engines.isEmpty) {
      log.logWarn(
        'No Flutter SDK was found, so only the age limit protected entries. '
        'Set FLUTTER_ROOT or put flutter on PATH to keep its cache.',
      );
    }
    if (result.removed.isEmpty) {
      log.logDone(
        'Nothing to prune (${result.kept.length} '
        '${result.kept.length == 1 ? 'entry' : 'entries'} in use or recent)',
      );
      return;
    }
    log.logDone(
      '${args.dryRun ? 'Would free' : 'Freed'} '
      '${formatBytes(result.freedBytes)} '
      '(${result.kept.length} kept)',
    );
    if (args.dryRun) return;
    if (result.removed.any((entry) => entry.kind == 'gen-snapshot')) {
      log.logStatus(
        log.dim('Removed compilers download again on the next AOT build.'),
      );
    }
  }
}

/// `1.2 MB`-style sizes for prune output.
@internal
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Reads the engine revision of the Flutter SDK at [root], or null.
@internal
String? flutterEngineRevision(PlatformHostInterface host, String root) {
  for (final relative in [
    ['bin', 'internal', 'engine.version'],
    ['bin', 'cache', 'engine.stamp'],
  ]) {
    try {
      final file = host.fileSystem.file(
        host.paths.context.joinAll([root, ...relative]),
      );
      if (!file.existsSync()) continue;
      final revision = file.readAsStringSync().trim();
      if (revision.isNotEmpty) return revision;
    } on Object {
      continue;
    }
  }
  return null;
}
