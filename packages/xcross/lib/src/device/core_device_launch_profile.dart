import 'package:dart_mobile_device/dart_mobile_device.dart'
    show TunnelConstants;
import 'package:xcross/src/flutter/models/hot_reload_config.dart';

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

  List<String> argumentsForLaunch({
    required bool isDap,
    bool ipv6VmService = false,
  }) => [
    if (_flutterRuntime && hotReload != null) ...[
      '--vm-service-host=${ipv6VmService ? '::0' : '0.0.0.0'}',
      '--vm-service-port=${TunnelConstants.vmServicePort}',
      '--disable-service-auth-codes',
      if (isDap) '--start-paused',
    ],
    if (_flutterRuntime) ...['--enable-checked-mode', '--verify-entry-points'],
    ...arguments,
  ];
}
