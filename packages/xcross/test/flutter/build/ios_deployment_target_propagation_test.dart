import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/flutter_debug_bundler.dart';
import 'package:xcross/src/flutter/build/internal/toolchain.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/runner_shim.dart';

void main() {
  test(
    'propagates deployment target to compiler linker and plist metadata',
    () {
      const target = IosDeploymentTarget('15.6');
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
