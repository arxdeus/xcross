// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'compose_setup_command.dart';

// **************************************************************************
// CliGenerator
// **************************************************************************

ComposeSetupArgs _$parseComposeSetupArgsResult(ArgResults result) =>
    ComposeSetupArgs()
      ..check = result['check'] as bool
      ..force = result['force'] as bool;

ArgParser _$populateComposeSetupArgsParser(ArgParser parser) => parser
  ..addFlag(
    'check',
    help: 'Check Compose toolchain prerequisites without installing anything.',
    negatable: false,
  )
  ..addFlag(
    'force',
    help: 'Refresh the Compose Kotlin/Native cache atomically.',
    negatable: false,
  );

final _$parserForComposeSetupArgs = _$populateComposeSetupArgsParser(
  ArgParser(),
);

ComposeSetupArgs parseComposeSetupArgs(List<String> args) {
  final result = _$parserForComposeSetupArgs.parse(args);
  return _$parseComposeSetupArgsResult(result);
}

abstract class _$ComposeSetupArgsCommand<T> extends Command<T> {
  _$ComposeSetupArgsCommand() {
    _$populateComposeSetupArgsParser(argParser);
  }

  late final _options = _$parseComposeSetupArgsResult(argResults!);
}
