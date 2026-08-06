import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:completion/completion.dart';

/// `xcross completion` — prints a shell completion script for `xcross`.
///
/// The generated script covers bash, zsh (compdef and compctl), and any
/// other shell exposing a compatible `complete`/`compdef` builtin.
///
/// Usage:
///   xcross completion >> ~/.bashrc
///   xcross completion >> ~/.zshrc
///
/// Then restart your shell (or `source` the file) to enable tab-completion.
///
/// The runtime `xcross completion -- ...` shell hook itself is handled
/// earlier in [XcrossCli.run] via `tryArgsCompletion`, before the command
/// runner parses args.
final class CompletionCommand extends Command<void> {
  @override
  String get name => 'completion';

  @override
  String get description =>
      'Print a shell completion script for xcross. '
      'Append the output to your shell config file (e.g. ~/.bashrc or '
      '~/.zshrc) to enable tab-completion.';

  @override
  void run() {
    stdout.write(generateCompletionScript(const ['xcross']));
  }
}
