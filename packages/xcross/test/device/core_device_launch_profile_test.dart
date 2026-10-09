import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';
import 'package:xcross/src/shared/flutter/models/hot_reload_config.dart';
import 'package:xcross/src/target/iphone/device/core_device_launch_profile.dart';

const _hotReload = HotReloadConfig(
  dart: '/flutter/bin/cache/dart-sdk/bin/dart',
  frontendServer: '/flutter/bin/cache/frontend_server.dart.snapshot',
  sdkRoot: '/flutter/bin/cache/artifacts/engine/common/flutter_patched_sdk',
  packageConfig: '/app/.dart_tool/package_config.json',
  entrypoint: '/app/lib/main.dart',
  projectRoot: '/app',
  outputDill: '/app/build/app.dill',
);

void main() {
  test('native profile forwards only application arguments', () {
    const profile = CoreDeviceLaunchProfile.native(arguments: ['--demo']);
    expect(
      profile.argumentsForLaunch(isDap: false, vmServiceBindAddress: '0.0.0.0'),
      ['--demo'],
    );
    expect(profile.hotReload, isNull);
    expect(profile.debuggingEnabled, isFalse);
    expect(profile.dartOutputFromDeviceLog, isFalse);
  });

  test('debug launch adds VM Service and checked-mode arguments', () {
    const profile = CoreDeviceLaunchProfile.flutter(
      buildMode: FlutterBuildMode.debug,
      arguments: ['--route=/home'],
      hotReload: _hotReload,
    );
    expect(
      profile.argumentsForLaunch(isDap: true, vmServiceBindAddress: '0.0.0.0'),
      [
        '--vm-service-host=0.0.0.0',
        '--vm-service-port=12345',
        '--disable-service-auth-codes',
        '--start-paused',
        '--enable-checked-mode',
        '--verify-entry-points',
        '--route=/home',
      ],
    );
    expect(profile.dartOutputFromDeviceLog, isFalse);
  });

  test('debug launch without hot reload still serves the VM Service', () {
    const profile = CoreDeviceLaunchProfile.flutter(
      buildMode: FlutterBuildMode.debug,
    );
    expect(
      profile.argumentsForLaunch(isDap: false, vmServiceBindAddress: '::0'),
      containsAll(['--vm-service-host=::0', '--enable-checked-mode']),
    );
    expect(profile.dartOutputFromDeviceLog, isTrue);
  });

  test('profile launch matches flutter run: VM Service, profiler, checks', () {
    const profile = CoreDeviceLaunchProfile.flutter(
      buildMode: FlutterBuildMode.profile,
      arguments: ['--route=/home'],
    );
    expect(profile.debuggingEnabled, isTrue);
    expect(profile.dartOutputFromDeviceLog, isTrue);
    expect(
      profile.argumentsForLaunch(isDap: false, vmServiceBindAddress: '0.0.0.0'),
      [
        '--enable-dart-profiling',
        '--vm-service-host=0.0.0.0',
        '--vm-service-port=12345',
        '--disable-service-auth-codes',
        '--enable-checked-mode',
        '--verify-entry-points',
        '--route=/home',
      ],
    );
  });

  test('release launch carries no VM Service or checked-mode flags', () {
    const profile = CoreDeviceLaunchProfile.flutter(
      buildMode: FlutterBuildMode.release,
      arguments: ['--route=/home'],
    );
    expect(profile.debuggingEnabled, isFalse);
    expect(profile.dartOutputFromDeviceLog, isTrue);
    expect(
      profile.argumentsForLaunch(isDap: false, vmServiceBindAddress: '::0'),
      ['--route=/home'],
    );
  });

  test('hot reload is rejected for precompiled builds', () {
    expect(
      () => CoreDeviceLaunchProfile.flutter(
        buildMode: FlutterBuildMode.profile,
        hotReload: _hotReload,
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('kernel tunnel binds VM Service to IPv6', () {
    const profile = CoreDeviceLaunchProfile.flutter(
      buildMode: FlutterBuildMode.debug,
      hotReload: _hotReload,
    );

    expect(
      profile.argumentsForLaunch(isDap: false, vmServiceBindAddress: '::0'),
      contains('--vm-service-host=::0'),
    );
  });
}
