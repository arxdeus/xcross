import 'package:args/command_runner.dart';

import 'package:xcross/src/cli/flutter/flutter_build_args.dart';
import 'package:xcross/src/cli/flutter/flutter_run_args.dart';

/// `xcross flutter` — parent command grouping `build` and `run`.
class FlutterCommand extends Command<void> {
  FlutterCommand() {
    addSubcommand(FlutterBuildCommand());
    addSubcommand(FlutterRunCommand());
  }

  @override
  String get name => 'flutter';

  @override
  String get description => 'Build and run Flutter iOS apps without Xcode.';
}
