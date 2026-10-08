import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';

@internal
abstract interface class ComposeSimulatorSigning<
  T extends PlatformHostInterface
> {
  T get host;
  Future<void> signBundle(String appPath);
}
