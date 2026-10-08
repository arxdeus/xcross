import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart';

@internal
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
