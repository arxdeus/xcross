// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'compose_run_command.dart';

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

ComposeRunArgs _$parseComposeRunArgsResult(ArgResults result) =>
    ComposeRunArgs()
      ..deviceId = result['device-id'] as String?
      ..udid = result['udid'] as String?
      ..usb = result['usb'] as bool
      ..wifi = result['wifi'] as bool
      ..deviceConnection = _$enumValueHelper(
        _$DeviceConnectionEnumMapBuildCli,
        result['device-connection'] as String,
      )
      ..appArgument = result['app-argument'] as List<String>
      ..watch = result['watch'] as bool
      ..verbose = result['verbose'] as bool;

const _$DeviceConnectionEnumMapBuildCli = <DeviceConnection, String>{
  DeviceConnection.attached: 'attached',
  DeviceConnection.wireless: 'wireless',
  DeviceConnection.both: 'both',
};

ArgParser _$populateComposeRunArgsParser(ArgParser parser) => parser
  ..addOption(
    'device-id',
    abbr: 'd',
    help: 'Target device id or name (flutter-style).',
  )
  ..addOption('udid', abbr: 'u', help: 'Target device UDID.')
  ..addFlag('usb', help: 'Search USB devices only.', negatable: false)
  ..addFlag('wifi', help: 'Search Wi-Fi devices only.', negatable: false)
  ..addOption(
    'device-connection',
    help: 'Discovery: attached (USB), wireless (Wi-Fi), or both.',
    defaultsTo: 'both',
    allowed: ['attached', 'wireless', 'both'],
  )
  ..addMultiOption(
    'app-argument',
    abbr: 'a',
    help: 'Pass arguments to the app main() (repeatable).',
  )
  ..addFlag(
    'watch',
    help:
        'Watch Kotlin sources and rebuild, reinstall, and relaunch on "r". Kotlin/Native is AOT-compiled, so this is a fast restart, not an in-place hot reload.',
    negatable: false,
  )
  ..addFlag('verbose', abbr: 'v', help: 'Verbose output.', negatable: false);

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
