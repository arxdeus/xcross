import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/compose/compose_simulator_signing.dart';

abstract interface class ComposeSimulatorCapability<
  T extends PlatformHostInterface
> {
  T get host;
  ComposeSimulatorSigning<T> requireSigning();
}
