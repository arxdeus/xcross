import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/compose/compose_host.dart';

@internal
abstract interface class ComposeHostProvider<T extends PlatformHostInterface> {
  T get host;
  ComposeHost<T> resolve();
}
