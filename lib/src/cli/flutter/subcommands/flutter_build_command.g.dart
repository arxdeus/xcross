// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'flutter_build_command.dart';

// **************************************************************************
// CliGenerator
// **************************************************************************

FlutterBuildArgs _$parseFlutterBuildArgsResult(ArgResults result) =>
    FlutterBuildArgs()
      ..target = result['target'] as String
      ..flavor = result['flavor'] as String?
      ..dartDefine = result['dart-define'] as List<String>
      ..dartDefineFromFile = result['dart-define-from-file'] as List<String>
      ..pub = result['pub'] as bool
      ..buildName = result['build-name'] as String?
      ..buildNumber = result['build-number'] as String?
      ..ipa = result['ipa'] as bool;

ArgParser _$populateFlutterBuildArgsParser(ArgParser parser) => parser
  ..addOption(
    'target',
    abbr: 't',
    help: 'The main entry-point file of the application.',
    defaultsTo: 'lib/main.dart',
  )
  ..addOption(
    'flavor',
    help: 'Build a custom app flavor (sets FLUTTER_APP_FLAVOR).',
  )
  ..addMultiOption(
    'dart-define',
    abbr: 'D',
    help: 'Pass a KEY=VALUE define to the Dart compiler.',
  )
  ..addMultiOption(
    'dart-define-from-file',
    help: 'Load dart-defines from a .json or .env file.',
  )
  ..addFlag(
    'pub',
    help: 'Run "flutter pub get" before building.',
    defaultsTo: true,
  )
  ..addOption('build-name', help: 'Version name (CFBundleShortVersionString).')
  ..addOption('build-number', help: 'Version code (CFBundleVersion).')
  ..addFlag(
    'ipa',
    abbr: 'i',
    help: 'Output a .ipa file instead of a .app.',
    negatable: false,
  );

final _$parserForFlutterBuildArgs = _$populateFlutterBuildArgsParser(
  ArgParser(),
);

FlutterBuildArgs parseFlutterBuildArgs(List<String> args) {
  final result = _$parserForFlutterBuildArgs.parse(args);
  return _$parseFlutterBuildArgsResult(result);
}

abstract class _$FlutterBuildArgsCommand<T> extends Command<T> {
  _$FlutterBuildArgsCommand() {
    _$populateFlutterBuildArgsParser(argParser);
  }

  late final _options = _$parseFlutterBuildArgsResult(argResults!);
}
