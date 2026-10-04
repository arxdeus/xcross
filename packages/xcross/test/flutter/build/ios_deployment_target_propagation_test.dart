import 'package:darwin_sdk_kit/target/iphone/iphone_build_platform.dart';
import 'package:darwin_sdk_kit/target/simulator/simulator_build_platform.dart';
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/flutter_debug_bundler.dart';
import 'package:xcross/src/shared/flutter/build/internal/toolchain.dart';
import 'package:xcross/src/shared/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/shared/flutter/build/runner_shim.dart';

void main() {
  test('propagates ARM64 simulator platform through App and Runner', () {
    const target = IosDeploymentTarget(
      '15.6',
      platform: SimulatorBuildPlatform(),
    );
    const toolchain = Toolchain(
      clang: '/clang',
      iosSdk: '/simulator-sdk',
      linker: '/ld64.lld',
    );
    final app = FlutterDebugBundler.appStubClangArgs(
      toolchain: toolchain,
      stubSource: '/stub.c',
      outputBinary: '/App',
      deploymentTarget: target,
    );
    expect(app, contains('--target=arm64-apple-ios15.6-simulator'));
    expect(app, contains('-mios-simulator-version-min=15.6'));
    expect(app, isNot(contains('-miphoneos-version-min=15.6')));
    final runner = RunnerShim.compileArguments(
      sourcePath: '/Runner.m',
      objectPath: '/Runner.o',
      iosSdk: '/simulator-sdk',
      subframeworks: '/subframeworks',
      flutterSlice: '/simulator',
      deploymentTarget: target,
    );
    expect(runner, contains('arm64-apple-ios15.6-simulator'));
    expect(runner, contains('-mios-simulator-version-min=15.6'));
    final link = RunnerShim.linkArguments(
      objectPath: '/Runner.o',
      outputPath: '/Runner',
      iosSdk: '/simulator-sdk',
      flutterSlice: '/simulator',
      subframeworks: '/subframeworks',
      sdkVersion: '26.5',
      deploymentTarget: target,
    );
    expect(
      link,
      containsAllInOrder([
        '-platform_version',
        'ios-simulator',
        '15.6',
        '26.5',
      ]),
    );
  });

  test(
    'propagates deployment target to compiler linker and plist metadata',
    () {
      const target = IosDeploymentTarget(
        '15.6',
        platform: IPhoneBuildPlatform(),
      );
      const toolchain = Toolchain(
        clang: '/toolchain/clang',
        iosSdk: '/sdk',
        linker: '/toolchain/ld64.lld',
      );

      final appArgs = FlutterDebugBundler.appStubClangArgs(
        toolchain: toolchain,
        stubSource: '/tmp/debug_app.c',
        outputBinary: '/tmp/App',
        deploymentTarget: target,
      );
      expect(appArgs, contains('--target=arm64-apple-ios15.6'));
      expect(appArgs, contains('-miphoneos-version-min=15.6'));

      final runnerCompileArgs = RunnerShim.compileArguments(
        sourcePath: '/tmp/Runner.m',
        objectPath: '/tmp/Runner.o',
        iosSdk: '/sdk',
        subframeworks: '/subframeworks',
        flutterSlice: '/flutter',
        deploymentTarget: target,
      );
      expect(runnerCompileArgs, contains('arm64-apple-ios15.6'));
      expect(runnerCompileArgs, contains('-miphoneos-version-min=15.6'));

      final runnerLinkArgs = RunnerShim.linkArguments(
        objectPath: '/tmp/Runner.o',
        outputPath: '/tmp/Runner',
        iosSdk: '/sdk',
        flutterSlice: '/flutter',
        subframeworks: '/subframeworks',
        sdkVersion: '18.0',
        deploymentTarget: target,
      );
      expect(
        runnerLinkArgs,
        containsAllInOrder(['-platform_version', 'ios', '15.6', '18.0']),
      );

      final plist = FlutterDebugBundler.appFrameworkInfoPlist(target);
      expect(plist, contains('<key>MinimumOSVersion</key>'));
      expect(plist, contains('<string>15.6</string>'));
    },
  );
}
