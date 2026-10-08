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
      ..targetPlatform = result['target-platform'] as String
      ..debug = result['debug'] as bool
      ..profile = result['profile'] as bool
      ..release = result['release'] as bool
      ..buildName = result['build-name'] as String?
      ..buildNumber = result['build-number'] as String?
      ..treeShakeIcons = result['tree-shake-icons'] as bool
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
  ..addOption(
    'target-platform',
    help: 'Target platform: iphone or simulator.',
    defaultsTo: 'iphone',
  )
  ..addFlag(
    'debug',
    help: 'Build in debug mode (the only supported mode).',
    negatable: false,
  )
  ..addFlag(
    'profile',
    help: 'Profile mode is unsupported by xcross.',
    negatable: false,
  )
  ..addFlag(
    'release',
    help: 'Release mode is unsupported by xcross.',
    negatable: false,
  )
  ..addOption('build-name', help: 'Version name (CFBundleShortVersionString).')
  ..addOption('build-number', help: 'Version code (CFBundleVersion).')
  ..addFlag(
    'tree-shake-icons',
    help:
        'Tree shake icon fonts so that only glyphs used by the application remain. Applies to profile and release builds.',
    defaultsTo: true,
  )
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
