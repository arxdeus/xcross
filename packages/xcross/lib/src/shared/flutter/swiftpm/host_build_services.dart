import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';

@internal
abstract interface class SwiftPmHostBuildServices<
  T extends PlatformHostInterface
> {
  IosTarget<T> get target;
  SwiftPmFilesystem<T> get filesystem;
  SwiftPmSdkIdentity get sdkIdentity;
  Future<void> stageFlutterFramework(
    String source,
    String destination, {
    bool? copy,
  });
  Future<String?> cCompiler(String sysroot);
  Future<String?> cxxCompiler(String sysroot);
  Future<void> configureToolset(
    Map<String, Object> toolset,
    String linker,
    String? cc,
    String? cxx,
  );
  Future<Map<String, Object>> buildToolchainIdentity(DarwinSdk? sdk);
  Future<void> rewriteDylib(String path, Set<String> names);
}
