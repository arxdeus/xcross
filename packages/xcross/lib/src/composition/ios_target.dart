import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';
import 'package:xcross/src/target/iphone/runtime/build_features.dart';
import 'package:xcross/src/target/shared/runtime/build_features.dart';
import 'package:xcross/src/target/simulator/runtime/build_features.dart';

@internal
XcrossBuildFeatures<T> composeBuildFeatures<T extends PlatformHostInterface>(
  String targetPlatform,
  XcrossRuntime<T> runtime, {
  bool ipa = false,
}) => switch (targetPlatform) {
  'iphone' => IPhoneBuildFeatures(runtime),
  'simulator' when ipa => throw XcrossError(
    'Simulator builds cannot be packaged as an IPA.',
  ),
  'simulator' => SimulatorBuildFeatures(runtime),
  _ => throw XcrossError(
    'Unknown target platform "$targetPlatform". Choose iphone or simulator.',
  ),
};

@internal
XcrossBuildFeatures<T> composePhysicalFeatures<T extends PlatformHostInterface>(
  XcrossRuntime<T> runtime,
) => IPhoneBuildFeatures(runtime);
