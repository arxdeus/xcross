import 'package:cli_kit/src/shared/platform/platform_host.dart';

abstract interface class PlatformTargetInterface<
  T extends PlatformHostInterface
> {
  T get host;
}
