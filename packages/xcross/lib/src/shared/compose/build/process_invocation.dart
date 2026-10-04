import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/compose/compose_host.dart';

final class ProcessInvocation {
  const ProcessInvocation({required this.executable, required this.arguments});
  final String executable;
  final List<String> arguments;
  factory ProcessInvocation.forHost(
    ComposeHost<PlatformHostInterface> host,
    String executable,
    List<String> arguments,
  ) => host.invocation(executable, arguments);
}
