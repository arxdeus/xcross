import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/compose/compose_simulator_signing.dart';

@internal
abstract interface class ComposeSimulatorCapability<
  T extends PlatformHostInterface
> {
  T get host;
  ComposeSimulatorSigning<T> requireSigning();
}
