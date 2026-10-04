import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/compose/build/compose_pack_operation.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain_resolver.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';

@internal
abstract interface class XcrossBuildFeatures<T extends PlatformHostInterface> {
  IosTarget<T> get target;
  FlutterBuildRuntime<T> get flutterRuntime;
  ComposePackOperation<T> get composeOperation;
  ComposeToolchainResolver<T> get composeResolver;
}
