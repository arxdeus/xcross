// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'cache_command.dart';

// **************************************************************************
// CliGenerator
// **************************************************************************

CachePruneArgs _$parseCachePruneArgsResult(ArgResults result) =>
    CachePruneArgs()
      ..dryRun = result['dry-run'] as bool
      ..olderThan = result['older-than'] as String;

ArgParser _$populateCachePruneArgsParser(ArgParser parser) => parser
  ..addFlag(
    'dry-run',
    help: 'List what would be removed without removing anything.',
    negatable: false,
  )
  ..addOption(
    'older-than',
    help:
        'Only remove entries unused for at least this many days. Entries for a Flutter SDK xcross can find are always kept.',
    valueHelp: 'days',
    defaultsTo: '30',
  );

final _$parserForCachePruneArgs = _$populateCachePruneArgsParser(ArgParser());

CachePruneArgs parseCachePruneArgs(List<String> args) {
  final result = _$parserForCachePruneArgs.parse(args);
  return _$parseCachePruneArgsResult(result);
}
