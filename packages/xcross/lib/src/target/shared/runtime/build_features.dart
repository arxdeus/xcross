import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/compose/build/compose_pack_operation.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain_resolver.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/swiftpm/package_builder.dart';

@internal
abstract interface class XcrossBuildFeatures<T extends PlatformHostInterface> {
  IosTarget<T> get target;
  FlutterBuildRuntime<T> get flutterRuntime;

  /// Builds Swift packages for [target] (for example a Compose SwiftUI
  /// host's package dependencies) through the shared SwiftPM engine.
  SwiftPmPackageBuilder<T> get swiftPmBuilder;
  ComposePackOperation<T> get composeOperation;
  ComposeToolchainResolver<T> get composeResolver;
}
