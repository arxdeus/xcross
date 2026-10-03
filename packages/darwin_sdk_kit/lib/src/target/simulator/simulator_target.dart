import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/src/target/shared/ios_target.dart';
import 'package:darwin_sdk_kit/src/target/simulator/simulator_build_platform.dart';

final class SimulatorTarget<T extends PlatformHostInterface>
    implements SimulatorTargetInterface<T> {
  const SimulatorTarget(this.host);
  @override
  final T host;
  @override
  SimulatorBuildPlatform get buildPlatform => const SimulatorBuildPlatform();
}
