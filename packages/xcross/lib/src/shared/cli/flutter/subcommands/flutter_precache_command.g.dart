// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'flutter_precache_command.dart';

// **************************************************************************
// CliGenerator
// **************************************************************************

FlutterPrecacheArgs _$parseFlutterPrecacheArgsResult(ArgResults result) =>
    FlutterPrecacheArgs()..mode = result['mode'] as String;

ArgParser _$populateFlutterPrecacheArgsParser(ArgParser parser) =>
    parser..addOption(
      'mode',
      help: 'Which build modes to fetch artifacts for.',
      defaultsTo: 'all',
      allowed: ['debug', 'profile', 'release', 'all'],
    );

final _$parserForFlutterPrecacheArgs = _$populateFlutterPrecacheArgsParser(
  ArgParser(),
);

FlutterPrecacheArgs parseFlutterPrecacheArgs(List<String> args) {
  final result = _$parserForFlutterPrecacheArgs.parse(args);
  return _$parseFlutterPrecacheArgsResult(result);
}
