import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/errors.dart';

Future<String> findDartExecutableOnPath({
  required ProcessRunner runner,
  required bool Function(String) acceptLauncher,
  Map<String, String>? environment,
  bool useConfiguration = true,
}) async {
  final executable = await runner.which(
    'dart',
    environment: environment,
    useConfiguration: useConfiguration,
    accept: acceptLauncher,
  );
  if (executable == null) {
    throw XcrossError(
      'failed to locate required executable "dart"; install it and ensure it is available on PATH',
    );
  }
  return runner.host.paths.context.absolute(executable);
}
