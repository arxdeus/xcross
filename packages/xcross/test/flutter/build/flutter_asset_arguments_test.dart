import 'dart:convert';

import 'package:darwin_sdk_kit/target/iphone/iphone_build_platform.dart';
import 'package:darwin_sdk_kit/target/simulator/simulator_build_platform.dart';
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/shared/flutter/build/ios_native_assets.dart';

import '../flutter_test_runtime.dart';

void main() {
  test(
    'native-hook simulator assembly selects simulator SDK in debug mode',
    () {
      final runtime = testSimulatorRuntime();
      final args =
          IosNativeAssetsBuilder(
            nativeAssetFrameworks: runtime.nativeAssetFrameworks,
            hooks: runtime.nativeAssetHooks,
            engineCache: runtime.engineCache('/flutter'),
            runner: runtime.runner,
            tools: runtime.nativeTools,
            renderer: runtime.toolShimRenderer,
            projectRoot: '/project',
            flutterRoot: '/flutter',
            deploymentTarget: const IosDeploymentTarget(
              '15.0',
              platform: SimulatorBuildPlatform(),
            ),
          ).assembleArguments(
            output: '/output',
            iosSdk: '/sdk/iPhoneSimulator26.5.sdk',
          );
      expect(args, contains('-dSdkRoot=/sdk/iPhoneSimulator26.5.sdk'));
      expect(args, contains('-dBuildMode=debug'));
      expect(args, contains('-dIosArchs=arm64'));
      expect(args.last, 'debug_ios_bundle_flutter_assets');
    },
  );

  for (final withHooks in [false, true]) {
    group(withHooks ? 'native-hook assembly' : 'bundle assembly', () {
      final runtime = testIPhoneRuntime();
      List<String> arguments(List<String> defines, {String? flavor}) =>
          IosNativeAssetsBuilder(
            nativeAssetFrameworks: runtime.nativeAssetFrameworks,
            hooks: runtime.nativeAssetHooks,
            engineCache: runtime.engineCache('/flutter'),
            runner: runtime.runner,
            tools: runtime.nativeTools,
            renderer: runtime.toolShimRenderer,
            projectRoot: '/project with spaces',
            flutterRoot: '/flutter',
            deploymentTarget: const IosDeploymentTarget(
              '15.0',
              platform: IPhoneBuildPlatform(),
            ),
            entrypoint: 'lib/entry point.dart',
            dartDefines: defines,
            flavor: flavor,
          ).assembleArguments(
            output: '/output with spaces',
            iosSdk: withHooks ? '/SDK with spaces' : null,
          );

      test('preserves compiler values and flavor without CLI validation', () {
        const defines = ['VALUE=one,two=three ü', 'MODE=first', 'MODE=last'];
        final args = arguments(defines, flavor: 'staging');
        expect(_decodedDefines(args), [
          ...defines,
          'FLUTTER_APP_FLAVOR=staging',
        ]);
        expect(args.first, 'assemble');
        expect(args, contains('-dTargetPlatform=ios'));
        expect(args, contains('-dIosArchs=arm64'));
        expect(args, contains('-dTargetFile=lib/entry point.dart'));
        expect(args[args.indexOf('-o') + 1], '/output with spaces');
        expect(
          args.last,
          withHooks ? 'debug_ios_bundle_flutter_assets' : 'copy_flutter_bundle',
        );
        expect(args.contains('-dSdkRoot=/SDK with spaces'), withHooks);
      });

      test('keeps the explicit flavor override and its precedence', () {
        const defines = ['FLUTTER_APP_FLAVOR=explicit'];
        expect(_decodedDefines(arguments(defines, flavor: 'staging')), defines);
      });

      test('does not invent a flavor for ordinary builds', () {
        expect(_decodedDefines(arguments(const [])), isEmpty);
      });
    });
  }
}

List<String> _decodedDefines(List<String> arguments) {
  final encoded = arguments
      .singleWhere((argument) => argument.startsWith('-dDartDefines='))
      .substring('-dDartDefines='.length);
  return encoded.isEmpty
      ? []
      : encoded
            .split(',')
            .map((value) => utf8.decode(base64.decode(value)))
            .toList();
}
