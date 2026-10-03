import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/host/linux/compose/linux_compose_host.dart';
import 'package:xcross/src/shared/compose/compose_host.dart';
import 'package:xcross/src/shared/runtime/compose_host_provider.dart';

final class LinuxComposeHostProvider<T extends LinuxHostInterface>
    implements ComposeHostProvider<T> {
  const LinuxComposeHostProvider(this.host);
  @override
  final T host;
  @override
  ComposeHost<T> resolve() => LinuxComposeHost(host);
}
