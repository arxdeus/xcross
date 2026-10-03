import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/compose/compose.dart';
import 'package:xcross/src/shared/runtime/compose_feature_factory.dart';

final class MacOSComposeFeatureFactory<T extends MacOSHostInterface>
    implements ComposeFeatureFactory<T> {
  const MacOSComposeFeatureFactory(this.host, this.runner);
  final T host;
  final ProcessRunner<T> runner;
  @override
  ComposeTarget<T> iphone(IPhoneTargetInterface<T> target) =>
      IPhoneComposeTarget(target, MacOSComposeHost(host));
  @override
  ComposeTarget<T> simulator(SimulatorTargetInterface<T> target) =>
      SimulatorComposeTarget(
        target,
        MacOSComposeHost(host),
        signing: MacOSComposeSimulatorSigning(runner),
      );
}
