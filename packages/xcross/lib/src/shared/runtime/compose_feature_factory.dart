import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/target/shared/compose/compose_target.dart';

abstract interface class ComposeFeatureFactory<
  T extends PlatformHostInterface
> {
  ComposeTarget<T> iphone(IPhoneTargetInterface<T> target);
  ComposeTarget<T> simulator(SimulatorTargetInterface<T> target);
}
