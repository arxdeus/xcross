// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'xcross_runner.dart';

// **************************************************************************
// CliGenerator
// **************************************************************************

XcrossGlobalArgs _$parseXcrossGlobalArgsResult(ArgResults result) =>
    XcrossGlobalArgs()
      ..verbose = result['verbose'] as bool
      ..version = result['version'] as bool;

ArgParser _$populateXcrossGlobalArgsParser(ArgParser parser) => parser
  ..addFlag(
    'verbose',
    abbr: 'v',
    help: 'Verbose output (show every command and tool line).',
    negatable: false,
  )
  ..addFlag(
    'version',
    help: 'Print the xcross version and exit.',
    negatable: false,
  );

final _$parserForXcrossGlobalArgs = _$populateXcrossGlobalArgsParser(
  ArgParser(),
);

XcrossGlobalArgs parseXcrossGlobalArgs(List<String> args) {
  final result = _$parserForXcrossGlobalArgs.parse(args);
  return _$parseXcrossGlobalArgsResult(result);
}
