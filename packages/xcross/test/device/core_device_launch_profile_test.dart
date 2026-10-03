import 'package:test/test.dart';
import 'package:xcross/src/device/core_device_launch_profile.dart';
import 'package:xcross/src/flutter/models/hot_reload_config.dart';

void main() {
  test('native profile forwards only application arguments', () {
    const profile = CoreDeviceLaunchProfile.native(arguments: ['--demo']);
    expect(
      profile.argumentsForLaunch(isDap: false, vmServiceBindAddress: '0.0.0.0'),
      ['--demo'],
    );
    expect(profile.hotReload, isNull);
  });

  test('flutter profile adds VM and checked-mode arguments', () {
    const hotReload = HotReloadConfig(
      dart: '/flutter/bin/cache/dart-sdk/bin/dart',
      frontendServer: '/flutter/bin/cache/frontend_server.dart.snapshot',
      sdkRoot: '/flutter/bin/cache/artifacts/engine/common/flutter_patched_sdk',
      packageConfig: '/app/.dart_tool/package_config.json',
      entrypoint: '/app/lib/main.dart',
      projectRoot: '/app',
      outputDill: '/app/build/app.dill',
    );
    const profile = CoreDeviceLaunchProfile.flutter(
      arguments: ['--route=/home'],
      hotReload: hotReload,
    );
    expect(
      profile.argumentsForLaunch(isDap: true, vmServiceBindAddress: '0.0.0.0'),
      containsAll([
        '--vm-service-host=0.0.0.0',
        '--disable-service-auth-codes',
        '--start-paused',
        '--enable-checked-mode',
        '--verify-entry-points',
        '--route=/home',
      ]),
    );
    expect(
      profile.argumentsForLaunch(isDap: true, vmServiceBindAddress: '0.0.0.0'),
      isNot(contains('--enable-dart-profiling')),
    );
  });

  test('kernel tunnel binds VM Service to IPv6', () {
    const hotReload = HotReloadConfig(
      dart: 'dart',
      frontendServer: 'frontend_server',
      sdkRoot: 'sdk',
      packageConfig: 'package_config.json',
      entrypoint: 'main.dart',
      projectRoot: '.',
      outputDill: 'app.dill',
    );
    const profile = CoreDeviceLaunchProfile.flutter(hotReload: hotReload);

    expect(
      profile.argumentsForLaunch(isDap: false, vmServiceBindAddress: '::0'),
      contains('--vm-service-host=::0'),
    );
  });
}
