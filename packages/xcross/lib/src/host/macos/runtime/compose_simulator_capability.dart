import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/compose/compose_simulator_signing.dart';
import 'package:xcross/src/shared/runtime/compose_simulator_capability.dart';

final class MacOSComposeSimulatorCapability<T extends MacOSHostInterface>
    implements ComposeSimulatorCapability<T> {
  const MacOSComposeSimulatorCapability(this.signing);
  final ComposeSimulatorSigning<T> signing;
  @override
  T get host => signing.host;
  @override
  ComposeSimulatorSigning<T> requireSigning() => signing;
}
