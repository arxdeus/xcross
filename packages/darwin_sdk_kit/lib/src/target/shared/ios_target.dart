import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/src/target/shared/ios_build_platform.dart';

abstract interface class IosTarget<T extends PlatformHostInterface>
    implements PlatformTargetInterface<T> {
  IosBuildPlatformInterface get buildPlatform;
}

abstract interface class IPhoneTargetInterface<T extends PlatformHostInterface>
    implements IosTarget<T> {}

abstract interface class SimulatorTargetInterface<
  T extends PlatformHostInterface
>
    implements IosTarget<T> {}
