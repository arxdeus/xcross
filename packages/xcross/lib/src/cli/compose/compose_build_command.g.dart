// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'compose_build_command.dart';

// **************************************************************************
// CliGenerator
// **************************************************************************

T _$enumValueHelper<T>(Map<T, String> enumValues, String source) => enumValues
    .entries
    .singleWhere(
      (e) => e.value == source,
      orElse: () => throw ArgumentError(
        '`$source` is not one of the supported values: '
        '${enumValues.values.join(', ')}',
      ),
    )
    .key;

ComposeBuildArgs _$parseComposeBuildArgsResult(ArgResults result) =>
    ComposeBuildArgs()
      ..configuration = _$enumValueHelper(
        _$ComposeConfigurationEnumMapBuildCli,
        result['configuration'] as String,
      )
      ..bundleId = result['bundle-id'] as String?
      ..appName = result['app-name'] as String?
      ..ipa = result['ipa'] as bool
      ..verbose = result['verbose'] as bool;

const _$ComposeConfigurationEnumMapBuildCli = <ComposeConfiguration, String>{
  ComposeConfiguration.debug: 'debug',
  ComposeConfiguration.release: 'release',
};

ArgParser _$populateComposeBuildArgsParser(ArgParser parser) => parser
  ..addOption(
    'configuration',
    help: 'Build configuration: debug or release.',
    defaultsTo: 'debug',
    allowed: ['debug', 'release'],
  )
  ..addOption('bundle-id', help: 'Override CFBundleIdentifier.')
  ..addOption('app-name', help: 'Override the iOS product name.')
  ..addFlag(
    'ipa',
    help:
        'Output a .ipa file instead of a .app when the project produces an app.',
    negatable: false,
  )
  ..addFlag(
    'verbose',
    abbr: 'v',
    help: 'Show full Gradle, Kotlin/Native, and linker output.',
    negatable: false,
  );

final _$parserForComposeBuildArgs = _$populateComposeBuildArgsParser(
  ArgParser(),
);

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
