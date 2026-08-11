import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:xcross/src/flutter/flutter.dart';

final class CoreDeviceLaunchProfile {
  const CoreDeviceLaunchProfile.native({this.arguments = const []})
    : hotReload = null,
      _flutterRuntime = false;

  const CoreDeviceLaunchProfile.flutter({
    required this.hotReload,
    this.arguments = const [],
  }) : _flutterRuntime = true;

  final List<String> arguments;
  final HotReloadConfig? hotReload;
  final bool _flutterRuntime;

  List<String> argumentsForLaunch({required bool isDap}) => [
    if (_flutterRuntime && hotReload != null) ...[
      '--vm-service-host=::',
      '--vm-service-port=${TunnelConstants.vmServicePort}',
      '--disable-service-auth-codes',
      if (isDap) '--start-paused',
    ],
    if (_flutterRuntime) ...['--enable-checked-mode', '--verify-entry-points'],
    ...arguments,
  ];
}
