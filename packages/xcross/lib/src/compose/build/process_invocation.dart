import 'package:xcross/src/compose/toolchain/compose_host.dart';

final class ProcessInvocation {
  const ProcessInvocation({required this.executable, required this.arguments});

  final String executable;
  final List<String> arguments;

  factory ProcessInvocation.forHost(
    ComposeHost host,
    String executable,
    List<String> arguments,
  ) {
    final invocation = host.invokeExecutable(executable, arguments);
    return ProcessInvocation(
      executable: invocation.first,
      arguments: invocation.skip(1).toList(growable: false),
    );
  }
}
