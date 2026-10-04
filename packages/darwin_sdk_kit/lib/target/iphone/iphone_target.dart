import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_build_platform.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';

final class IPhoneTarget<T extends PlatformHostInterface>
    implements IPhoneTargetInterface<T> {
  const IPhoneTarget(this.host);
  @override
  final T host;
  @override
  IPhoneBuildPlatform get buildPlatform => const IPhoneBuildPlatform();
}
