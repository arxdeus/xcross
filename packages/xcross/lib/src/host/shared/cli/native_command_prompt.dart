import 'dart:io';

import 'package:xcross/src/shared/cli/command_prompt.dart';
import 'package:xcross/src/shared/errors/errors.dart';

final class NativeCommandPrompt implements CommandPrompt {
  NativeCommandPrompt({required Stdin input, required StringSink output})
    : _input = input,
      _output = output;

  final Stdin _input;
  final StringSink _output;

  @override
  bool get isInteractive => _input.hasTerminal;

  @override
  void write(String value) => _output.write(value);

  @override
  String? readLine(String prompt) {
    write(prompt);
    return _input.readLineSync();
  }

  @override
  String? readSecret(String prompt, {required String valueName}) {
    if (!isInteractive) {
      throw XcrossError('$valueName prompt requires an interactive terminal.');
    }
    write(prompt);

    final bool priorEcho;
    final bool priorLine;
    try {
      priorEcho = _input.echoMode;
      priorLine = _input.lineMode;
    } on Object catch (error) {
      throw XcrossError('Secure $valueName input is unavailable: $error');
    }

    try {
      try {
        _input.lineMode = true;
        _input.echoMode = false;
      } on Object catch (error) {
        throw XcrossError(
          'Could not disable terminal echo; refusing to read the $valueName: $error',
        );
      }
      final value = _input.readLineSync();
      return value != null && value.isNotEmpty ? value : null;
    } finally {
      _trySet(() => _input.echoMode = priorEcho);
      _trySet(() => _input.lineMode = priorLine);
      _output.writeln();
    }
  }

  static void _trySet(void Function() setMode) {
    try {
      setMode();
    } on Object {
      return;
    }
  }
}
