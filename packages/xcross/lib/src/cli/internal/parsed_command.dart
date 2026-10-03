import 'package:args/args.dart';
import 'package:args/command_runner.dart';

abstract class ParsedCommand<Options, Result> extends Command<Result> {
  ParsedCommand() {
    populateOptions(argParser);
  }

  ArgParser populateOptions(ArgParser parser);
  Options parseOptions(ArgResults results);
  Options get options => parseOptions(argResults!);
}
