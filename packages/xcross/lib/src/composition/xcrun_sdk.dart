import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';

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
