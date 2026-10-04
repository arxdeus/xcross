import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart';

abstract interface class AppleToolShimRenderer<
  T extends PlatformHostInterface
> {
  T get host;
  Future<void> install(
    String directory,
    AppleToolShimConfig config, {
    String? toolForwarderExecutable,
  });
}
