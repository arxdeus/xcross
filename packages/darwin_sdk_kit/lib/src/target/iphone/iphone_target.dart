import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/src/target/iphone/iphone_build_platform.dart';
import 'package:darwin_sdk_kit/src/target/shared/ios_target.dart';

final class IPhoneTarget<T extends PlatformHostInterface>
    implements IPhoneTargetInterface<T> {
  const IPhoneTarget(this.host);
  @override
  final T host;
  @override
  IPhoneBuildPlatform get buildPlatform => const IPhoneBuildPlatform();
}
