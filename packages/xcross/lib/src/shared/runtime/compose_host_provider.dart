import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/compose/compose_host.dart';

abstract interface class ComposeHostProvider<T extends PlatformHostInterface> {
  T get host;
  ComposeHost<T> resolve();
}
