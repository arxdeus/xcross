import 'dart:convert';

import 'package:cli_kit/src/errors.dart';
import 'package:path/path.dart' as p;

abstract final class WindowsBatchPolicy {
  static bool isBatchScript(String executable) {
    final extension = p.windows.extension(executable).toLowerCase();
    return extension == '.bat' || extension == '.cmd';
  }

  static final _batchNeverSafe = RegExp('["%\r\n]');
  static final _batchWhitespace = RegExp('[ \t]');
  static final _batchOperators = RegExp('[&|<>^]');
  static final _batchQuotedCommandSpecial = RegExp('[&<>()@^|]');

  static List<String> arguments(List<String> arguments, {String? executable}) {
    final quotedExecutable =
        executable != null && _batchWhitespace.hasMatch(executable);
    if (executable != null &&
        (_batchNeverSafe.hasMatch(executable) ||
            (quotedExecutable ? _batchQuotedCommandSpecial : _batchOperators)
                .hasMatch(executable))) {
      throw CliError(
        'batch script path ${jsonEncode(executable)} cannot be started '
        'through cmd.exe; move it to a path without `%`, quotes or '
        '`&<>()@^|` next to spaces',
      );
    }
    return [
      for (final argument in arguments)
        _windowsBatchArgument(argument, quotedExecutable: quotedExecutable),
    ];
  }

  static String _windowsBatchArgument(
    String argument, {
    required bool quotedExecutable,
  }) {
    final quoted = argument.isEmpty || _batchWhitespace.hasMatch(argument);
    final unsafe =
        argument.contains('"') ||
        argument.contains('\r') ||
        argument.contains('\n') ||
        (quoted
            ? argument.contains('%') || quotedExecutable
            : _batchOperators.hasMatch(argument));
    if (unsafe) {
      throw CliError(
        'argument ${jsonEncode(argument)} cannot be passed through cmd.exe '
        'to a Windows batch script unchanged',
      );
    }
    return quoted ? argument : argument.replaceAll('%', '^%');
  }
}
