import 'package:cli_kit/cli_kit_shared.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart' show Pymd;
import 'package:dart_mobile_device/dart_mobile_device_shared.dart'
    show DeviceSockets;
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';

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
