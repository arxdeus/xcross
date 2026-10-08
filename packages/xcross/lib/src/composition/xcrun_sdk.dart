import 'package:darwin_sdk_kit/target/iphone/iphone_build_platform.dart';
import 'package:darwin_sdk_kit/target/shared/ios_build_platform.dart';
import 'package:darwin_sdk_kit/target/simulator/simulator_build_platform.dart';
import 'package:meta/meta.dart';

@internal
IosBuildPlatformInterface parseXcrunSdkName(String name) {
  final normalized = name.toLowerCase();
  for (final target in const <IosBuildPlatformInterface>[
    IPhoneBuildPlatform(),
    SimulatorBuildPlatform(),
  ]) {
    if (RegExp(
      '^${target.sdkName}(?:[0-9]+(?:\\.[0-9]+)*)?\$',
    ).hasMatch(normalized)) {
      return target;
    }
  }
  throw FormatException('SDK $name is not installed');
}
