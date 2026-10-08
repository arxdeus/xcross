import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/windows/compose/windows_compose_host.dart';
import 'package:xcross/src/shared/compose/compose_host.dart';
import 'package:xcross/src/shared/runtime/compose_host_provider.dart';

@internal
final class WindowsComposeHostProvider<T extends WindowsHostInterface>
    implements ComposeHostProvider<T> {
  const WindowsComposeHostProvider(this.host, this.runningExecutable);
  @override
  final T host;
  final String runningExecutable;
  @override
  ComposeHost<T> resolve() =>
      WindowsComposeHost(host, runningExecutable: runningExecutable);
}
