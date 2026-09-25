import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:xcross/src/errors.dart';

Future<String> findDartExecutableOnPath({
  bool? windows,
  Map<String, String>? environment,
  bool useConfiguration = true,
}) async {
  final onWindows = windows ?? Platform.isWindows;
  final executable = await ProcessRunner.which(
    'dart',
    environment: environment,
    windows: onWindows,
    useConfiguration: useConfiguration,
    accept: (path) => _isDartLauncher(path, windows: onWindows),
  );
  if (executable == null) {
    throw XcrossError(
      'failed to locate required executable "dart"; install it and ensure '
      'it is available on PATH',
    );
  }
  return executable;
}

bool _isDartLauncher(String path, {required bool windows}) {
  final name = p.basename(path);
  if (!windows) return name == 'dart' && posix.access(path, posix.X_OK) == 0;

  return switch (name.toLowerCase()) {
    'dart.exe' || 'dart.bat' || 'dart.cmd' => true,
    _ => false,
  };
}
