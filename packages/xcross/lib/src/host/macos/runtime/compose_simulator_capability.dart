import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/host/macos/compose/macos_compose_simulator_signing.dart';
import 'package:xcross/src/shared/compose/compose_simulator_signing.dart';
import 'package:xcross/src/shared/runtime/compose_simulator_capability.dart';

final class MacOSComposeSimulatorCapability<T extends MacOSHostInterface>
    implements ComposeSimulatorCapability<T> {
  const MacOSComposeSimulatorCapability(this.runner);
  final ProcessRunner<T> runner;
  @override
  T get host => runner.host;
  @override
  ComposeSimulatorSigning<T> requireSigning() =>
      MacOSComposeSimulatorSigning(runner);
}
