import 'package:test/test.dart';
import 'package:xcross/src/device/core_device_launch_profile.dart';
import 'package:xcross/src/flutter/flutter.dart';

void main() {
  test('native profile forwards only application arguments', () {
    const profile = CoreDeviceLaunchProfile.native(arguments: ['--demo']);
    expect(profile.argumentsForLaunch(isDap: false), ['--demo']);
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
      profile.argumentsForLaunch(isDap: true),
      containsAll([
        '--vm-service-host=::',
        '--disable-service-auth-codes',
        '--start-paused',
        '--enable-checked-mode',
        '--verify-entry-points',
        '--route=/home',
      ]),
    );
  });
}
