import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/src/target/shared/ios_build_platform.dart';

abstract interface class IosTarget<T extends PlatformHostInterface>
    implements PlatformTargetInterface<T> {
  IosBuildPlatformInterface get buildPlatform;
  R accept<R>(IosTargetVisitor<R, T> visitor);
}

abstract interface class IPhoneTargetInterface<T extends PlatformHostInterface>
    implements IosTarget<T> {}

abstract interface class SimulatorTargetInterface<
  T extends PlatformHostInterface
>
    implements IosTarget<T> {}

abstract interface class IosTargetVisitor<R, T extends PlatformHostInterface> {
  R visitIPhone(IPhoneTargetInterface<T> target);
  R visitSimulator(SimulatorTargetInterface<T> target);
}
