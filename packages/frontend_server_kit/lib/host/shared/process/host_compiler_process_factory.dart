import 'package:cli_kit/shared/process/process.dart';
import 'package:frontend_server_kit/shared/process/compiler_transport.dart';
import 'package:frontend_server_kit/src/host/shared/process/host_compiler_process_factory.dart';

final class HostCompilerProcessFactory implements CompilerProcessFactory {
  const HostCompilerProcessFactory(this.runner);

  final ProcessRunner runner;

  @override
  Future<CompilerTransport> start(
    String executable,
    List<String> arguments,
  ) async =>
      HostCompilerTransport(await runner.start(executable, arguments), runner);
}
