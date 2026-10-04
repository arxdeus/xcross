import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_build_services.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';

abstract class PosixSwiftPmHostBuildServices<T extends PlatformHostInterface>
    implements SwiftPmHostBuildServices<T> {
  PosixSwiftPmHostBuildServices({
    required this.target,
    required this.filesystem,
    required this.sdkIdentity,
  }) {
    if (!identical(target.host, filesystem.host)) {
      throw ArgumentError(
        'SwiftPM host services must share the configured target host',
      );
    }
  }
  @override
  final IosTarget<T> target;
  @override
  final SwiftPmFilesystem<T> filesystem;
  @override
  final SwiftPmSdkIdentity sdkIdentity;
  @override
  Future<void> stageFlutterFramework(
    String source,
    String destination, {
    bool? copy,
  }) => filesystem.stageFlutterFramework(
    source,
    destination,
    copy: copy ?? false,
  );
  @override
  Future<String?> cCompiler(String sysroot) => Future.value();
  @override
  Future<String?> cxxCompiler(String sysroot) => Future.value();
  @override
  Future<void> configureToolset(
    Map<String, Object> toolset,
    String linker,
    String? cc,
    String? cxx,
  ) => Future.value();
  @override
  Future<Map<String, Object>> buildToolchainIdentity(DarwinSdk? sdk) =>
      sdkIdentity.hostToolchainIdentity();
}
