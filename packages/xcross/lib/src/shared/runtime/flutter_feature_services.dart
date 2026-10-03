import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

abstract interface class FlutterFeatureServices<
  T extends PlatformHostInterface
> {
  ProcessRunner<T> get runner;
  FlutterBuildRuntime<T> build(FlutterTargetBuildPolicy<T> policy);
}
