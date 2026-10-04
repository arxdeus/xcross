import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/compose/compose_host.dart';

@internal
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
