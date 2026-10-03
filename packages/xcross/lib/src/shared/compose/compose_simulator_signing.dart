import 'package:cli_kit/cli_kit_shared.dart';

abstract interface class ComposeSimulatorSigning<
  T extends PlatformHostInterface
> {
  T get host;
  Future<void> signBundle(String appPath);
}
