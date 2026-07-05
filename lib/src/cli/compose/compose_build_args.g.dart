// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'compose_build_args.dart';

// **************************************************************************
// CliGenerator
// **************************************************************************

T _$enumValueHelper<T>(Map<T, String> enumValues, String source) =>
    enumValues.entries
        .singleWhere(
          (e) => e.value == source,
          orElse: () => throw ArgumentError(
            '`$source` is not one of the supported values: '
            '${enumValues.values.join(', ')}',
          ),
        )
        .key;

ComposeBuildArgs _$parseComposeBuildArgsResult(ArgResults result) =>
    ComposeBuildArgs(
      configuration: _$enumValueHelper(
        _$ComposeConfigurationEnumMapBuildCli,
        result['configuration'] as String,
      ),
      sign: result['sign'] as bool,
      codesign: result['codesign'] as bool,
      ipa: result['ipa'] as bool,
    );

const _$ComposeConfigurationEnumMapBuildCli = <ComposeConfiguration, String>{
  ComposeConfiguration.debug: 'debug',
  ComposeConfiguration.release: 'release'
};

ArgParser _$populateComposeBuildArgsParser(ArgParser parser) => parser
  ..addOption(
    'configuration',
    abbr: 'c',
    help: 'Build configuration (release default).',
    defaultsTo: 'release',
    allowed: ['debug', 'release'],
  )
  ..addFlag(
    'sign',
    abbr: 's',
    help: 'Codesign the built app (delegates to `xtool install`).',
    negatable: false,
  )
  ..addFlag(
    'codesign',
    help: 'Alias of --sign (flutter-style).',
  )
  ..addFlag(
    'ipa',
    abbr: 'i',
    help: 'Output a .ipa archive instead of a bare .app.',
    negatable: false,
  );

final _$parserForComposeBuildArgs =
    _$populateComposeBuildArgsParser(ArgParser());

ComposeBuildArgs parseComposeBuildArgs(List<String> args) {
  final result = _$parserForComposeBuildArgs.parse(args);
  return _$parseComposeBuildArgsResult(result);
}

abstract class _$ComposeBuildArgsCommand<T> extends Command<T> {
  _$ComposeBuildArgsCommand() {
    _$populateComposeBuildArgsParser(argParser);
  }

  late final _options = _$parseComposeBuildArgsResult(argResults!);
}
