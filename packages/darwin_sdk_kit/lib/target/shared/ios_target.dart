import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/target/shared/platform_target.dart';
import 'package:darwin_sdk_kit/target/shared/ios_build_platform.dart';

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
