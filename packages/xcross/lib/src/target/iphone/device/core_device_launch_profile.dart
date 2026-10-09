import 'package:dart_mobile_device/target/iphone/device/constants.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';
import 'package:xcross/src/shared/flutter/models/hot_reload_config.dart';

@internal
final class CoreDeviceLaunchProfile {
  const CoreDeviceLaunchProfile.native({this.arguments = const []})
    : buildMode = null,
      hotReload = null;

  /// [hotReload] applies to debug builds only: precompiled code cannot be
  /// reloaded in place.
  const CoreDeviceLaunchProfile.flutter({
    required FlutterBuildMode this.buildMode,
    this.hotReload,
    this.arguments = const [],
  }) : assert(
         hotReload == null || buildMode == FlutterBuildMode.debug,
         'hot reload needs a debug build',
       );

  final List<String> arguments;

  /// The Flutter build mode, or null for a native app.
  final FlutterBuildMode? buildMode;
  final HotReloadConfig? hotReload;

  /// Debug and profile builds run with debugging enabled, as `flutter run`
  /// launches them: the app serves the Dart VM Service and gets the
  /// checked-mode flags. Release builds carry no VM Service.
  bool get debuggingEnabled =>
      buildMode != null && buildMode != FlutterBuildMode.release;

  /// Profile builds enable the Dart sampling profiler for DevTools, as
  /// `flutter run` does. Debug launches leave it off, and release engines
  /// ship without the profiler.
  bool get enableDartProfiling => buildMode == FlutterBuildMode.profile;

  /// Whether the app's Dart output only reaches the device log: without a
  /// hot-reload session nothing forwards the VM Service's stdout stream.
  bool get dartOutputFromDeviceLog => buildMode != null && hotReload == null;

  List<String> argumentsForLaunch({
    required bool isDap,
    required String vmServiceBindAddress,
  }) => [
    if (enableDartProfiling) '--enable-dart-profiling',
    if (debuggingEnabled) ...[
      '--vm-service-host=$vmServiceBindAddress',
      '--vm-service-port=${TunnelConstants.vmServicePort}',
      '--disable-service-auth-codes',
      if (isDap) '--start-paused',
      '--enable-checked-mode',
      '--verify-entry-points',
    ],
    ...arguments,
  ];
}
