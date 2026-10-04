import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';

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
