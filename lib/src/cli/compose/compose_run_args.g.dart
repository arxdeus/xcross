// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'compose_run_args.dart';

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

ComposeRunArgs _$parseComposeRunArgsResult(ArgResults result) => ComposeRunArgs(
      configuration: _$enumValueHelper(
        _$ComposeConfigurationEnumMapBuildCli,
        result['configuration'] as String,
      ),
      deviceId: result['device-id'] as String?,
      udid: result['udid'] as String?,
      usb: result['usb'] as bool,
      network: result['network'] as bool,
      dartEntrypointArgs: result['dart-entrypoint-args'] as List<String>,
    );

const _$ComposeConfigurationEnumMapBuildCli = <ComposeConfiguration, String>{
  ComposeConfiguration.debug: 'debug',
  ComposeConfiguration.release: 'release'
};

ArgParser _$populateComposeRunArgsParser(ArgParser parser) => parser
  ..addOption(
    'configuration',
    abbr: 'c',
    help: 'Build configuration (debug default for run).',
    defaultsTo: 'debug',
    allowed: ['debug', 'release'],
  )
  ..addOption(
    'device-id',
    abbr: 'd',
    help: 'Target device id or name (flutter-style).',
  )
  ..addOption(
    'udid',
    abbr: 'u',
    help: 'Target device UDID (xtool-style).',
  )
  ..addFlag(
    'usb',
    help: 'Search USB-connected devices only.',
    negatable: false,
  )
  ..addFlag(
    'network',
    help: 'Search Wi-Fi / network devices only.',
    negatable: false,
  )
  ..addMultiOption(
    'dart-entrypoint-args',
    abbr: 'a',
    help: 'Arguments passed to the app binary (repeatable).',
  );

final _$parserForComposeRunArgs = _$populateComposeRunArgsParser(ArgParser());

ComposeRunArgs parseComposeRunArgs(List<String> args) {
  final result = _$parserForComposeRunArgs.parse(args);
  return _$parseComposeRunArgsResult(result);
}

abstract class _$ComposeRunArgsCommand<T> extends Command<T> {
  _$ComposeRunArgsCommand() {
    _$populateComposeRunArgsParser(argParser);
  }

  late final _options = _$parseComposeRunArgsResult(argResults!);
}
