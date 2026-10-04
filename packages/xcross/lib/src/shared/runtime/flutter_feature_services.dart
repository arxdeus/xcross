import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

@internal
abstract interface class FlutterFeatureServices<
  T extends PlatformHostInterface
> {
  ProcessRunner<T> get runner;
  FlutterBuildRuntime<T> build(FlutterTargetBuildPolicy<T> policy);
}
