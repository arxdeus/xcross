import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/compose/build/compose_pack_operation.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain_resolver.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';

abstract interface class XcrossBuildFeatures<T extends PlatformHostInterface> {
  IosTarget<T> get target;
  FlutterBuildRuntime<T> get flutterRuntime;
  ComposePackOperation<T> get composeOperation;
  ComposeToolchainResolver<T> get composeResolver;
}
