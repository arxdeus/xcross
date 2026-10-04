import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_build_platform.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/sdk/sdk_metadata_platform.dart';

@internal
final class IPhoneSdkMetadataPlatform<T extends PlatformHostInterface>
    implements SdkMetadataPlatformInterface<T> {
  const IPhoneSdkMetadataPlatform();
  @override
  IPhoneBuildPlatform get buildPlatform => const IPhoneBuildPlatform();
  @override
  String resolveSdkRoot(DarwinSdkRepository<T> repository, DarwinSdk sdk) =>
      repository.iosSdk(sdk, target: buildPlatform);
}
