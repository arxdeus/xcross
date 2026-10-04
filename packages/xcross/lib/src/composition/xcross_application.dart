import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:dart_mobile_device/shared/network/device_sockets.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';

@internal
final class XcrossApplication<T extends PlatformHostInterface> {
  XcrossApplication({
    required this.runtime,
    required this.pymd,
    required this.sockets,
  }) {
    if (!identical(runtime.runner, pymd.runner)) {
      throw ArgumentError(
        'Application services must share one configured runner',
      );
    }
  }

  final XcrossRuntime<T> runtime;
  final Pymd pymd;
  final DeviceSockets sockets;
}
