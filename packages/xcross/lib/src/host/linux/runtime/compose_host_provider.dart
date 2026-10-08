import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/linux/compose/linux_compose_host.dart';
import 'package:xcross/src/shared/compose/compose_host.dart';
import 'package:xcross/src/shared/runtime/compose_host_provider.dart';

@internal
final class LinuxComposeHostProvider<T extends LinuxHostInterface>
    implements ComposeHostProvider<T> {
  const LinuxComposeHostProvider(this.host);
  @override
  final T host;
  @override
  ComposeHost<T> resolve() => LinuxComposeHost(host);
}
