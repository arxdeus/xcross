import 'dart:io';

import 'package:xcross/src/errors.dart';

Future<ProcessResult> runUpdateProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  try {
    return await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
  } on ProcessException {
    throw XcrossError(
      'failed to start required executable "$executable"; install it and '
      'ensure it is available on PATH',
    );
  }
}
