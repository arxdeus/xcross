import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';

abstract interface class SdkMetadataPlatformInterface<
  T extends PlatformHostInterface
> {
  IosBuildPlatformInterface get buildPlatform;
  String? resolveSdkRoot(DarwinSdkRepository<T> repository, DarwinSdk sdk);
}
