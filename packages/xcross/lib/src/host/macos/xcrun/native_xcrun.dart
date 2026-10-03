import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/xcrun/xcrun_operation.dart';

typedef NativeXcrunStart =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      required ProcessStartMode mode,
    });

final class NativeMacXcrun implements XcrunOperation {
  const NativeMacXcrun(this.host, {NativeXcrunStart? start}) : _start = start;
  final MacOSHostInterface host;
  final NativeXcrunStart? _start;

  @override
  Future<int> run(List<String> arguments) async {
    final child = _start == null
        ? await host.processes.start(
            '/usr/bin/xcrun',
            arguments,
            environment: host.environment.values,
            includeParentEnvironment: false,
            mode: ProcessStartMode.inheritStdio,
          )
        : await _start(
            '/usr/bin/xcrun',
            arguments,
            mode: ProcessStartMode.inheritStdio,
          );
    return child.exitCode;
  }
}
