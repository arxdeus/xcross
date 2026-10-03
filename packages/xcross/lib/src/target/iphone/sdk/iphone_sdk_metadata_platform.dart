import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_iphone.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/shared/sdk/sdk_metadata_platform.dart';

final class IPhoneSdkMetadataPlatform<T extends PlatformHostInterface>
    implements SdkMetadataPlatformInterface<T> {
  const IPhoneSdkMetadataPlatform();
  @override
  IPhoneBuildPlatform get buildPlatform => const IPhoneBuildPlatform();
  @override
  String resolveSdkRoot(DarwinSdkRepository<T> repository, DarwinSdk sdk) =>
      repository.iosSdk(sdk, target: buildPlatform);
}
