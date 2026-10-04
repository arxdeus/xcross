import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/compose/compose_simulator_signing.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/runtime/compose_simulator_capability.dart';

final class UnsupportedComposeSimulatorCapability<
  T extends PlatformHostInterface
>
    implements ComposeSimulatorCapability<T> {
  const UnsupportedComposeSimulatorCapability(this.host);
  @override
  final T host;
  @override
  ComposeSimulatorSigning<T> requireSigning() => throw XcrossError(
    'Compose iOS simulator builds are supported only on macOS.',
  );
}
