import 'package:dart_mobile_device/target/iphone/device/constants.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/models/hot_reload_config.dart';

@internal
final class CoreDeviceLaunchProfile {
  const CoreDeviceLaunchProfile.native({this.arguments = const []})
    : hotReload = null,
      debuggingEnabled = false,
      _flutterRuntime = false;

  const CoreDeviceLaunchProfile.flutter({
    required this.hotReload,
    this.arguments = const [],
    this.debuggingEnabled = true,
  }) : _flutterRuntime = true;

  final List<String> arguments;
  final HotReloadConfig? hotReload;
  final bool _flutterRuntime;

  /// Debug (JIT) builds run with checked mode; profile and release builds
  /// run precompiled code, which rejects those flags, as `flutter run` does.
  final bool debuggingEnabled;

  List<String> argumentsForLaunch({
    required bool isDap,
    required String vmServiceBindAddress,
  }) => [
    if (_flutterRuntime && hotReload != null) ...[
      '--vm-service-host=$vmServiceBindAddress',
      '--vm-service-port=${TunnelConstants.vmServicePort}',
      '--disable-service-auth-codes',
      if (isDap) '--start-paused',
    ],
    if (_flutterRuntime && debuggingEnabled) ...[
      '--enable-checked-mode',
      '--verify-entry-points',
    ],
    ...arguments,
  ];
}
