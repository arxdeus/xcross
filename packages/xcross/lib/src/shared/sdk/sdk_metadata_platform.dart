import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/target/shared/ios_build_platform.dart';
import 'package:meta/meta.dart';

@internal
abstract interface class SdkMetadataPlatformInterface<
  T extends PlatformHostInterface
> {
  IosBuildPlatformInterface get buildPlatform;
  String? resolveSdkRoot(DarwinSdkRepository<T> repository, DarwinSdk sdk);
}
