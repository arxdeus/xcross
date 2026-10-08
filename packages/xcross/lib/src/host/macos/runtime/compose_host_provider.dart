import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/macos/compose/macos_compose_host.dart';
import 'package:xcross/src/shared/compose/compose_host.dart';
import 'package:xcross/src/shared/runtime/compose_host_provider.dart';

@internal
final class MacOSComposeHostProvider<T extends MacOSHostInterface>
    implements ComposeHostProvider<T> {
  const MacOSComposeHostProvider(this.host);
  @override
  final T host;
  @override
  ComposeHost<T> resolve() => MacOSComposeHost(host);
}
