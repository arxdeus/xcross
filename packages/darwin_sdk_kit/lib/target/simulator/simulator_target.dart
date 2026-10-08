import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:darwin_sdk_kit/target/simulator/simulator_build_platform.dart';

final class SimulatorTarget<T extends PlatformHostInterface>
    implements SimulatorTargetInterface<T> {
  const SimulatorTarget(this.host);
  @override
  final T host;
  @override
  SimulatorBuildPlatform get buildPlatform => const SimulatorBuildPlatform();
}
