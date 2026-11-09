import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';
import 'package:xcross/src/target/shared/flutter/ios_plist_metadata.dart';
import 'package:xcross/src/target/shared/flutter/xcode_build_metadata.dart';
import 'package:xcross/src/target/simulator/swiftpm/simulator_swiftpm_target.dart';

@internal
final class SimulatorFlutterTarget<T extends PlatformHostInterface>
    implements FlutterTargetBuildPolicy<T> {
  const SimulatorFlutterTarget(this.target);

  /// The SwiftPM half of this policy, the single source of the workspace
  /// suffix (part of the SwiftPM cache key), slices and artifact store.
  SimulatorSwiftPmTarget<T> get _swiftPm => SimulatorSwiftPmTarget(target);

  @override
  final SimulatorTargetInterface<T> target;
  @override
  String outputDirectory(String projectRoot) => target.host.paths.context.join(
    projectRoot,
    'build',
    'xcross-ios-simulator',
  );
  @override
  String buildDirectory(String projectRoot, String name) =>
      target.host.paths.context.join(outputDirectory(projectRoot), name);
  @override
  String get engineArtifact => 'ios';
  @override
  bool get supportsPrecompiledModes => false;
  @override
  bool get embedsEntitlements => false;
  @override
  List<String> get engineSliceIdentifiers => const [
    'ios-arm64_x86_64-simulator',
    'ios-arm64-simulator',
  ];
  @override
  List<String> get xcframeworkSliceIdentifiers =>
      _swiftPm.xcframeworkSliceIdentifiers;
  @override
  String selectEngineSlice(String xcframework) => selectFlutterEngineSlice(
    xcframework,
    engineSliceIdentifiers,
    paths: target.host.paths.context,
    fileSystem: target.host.fileSystem,
  );
  @override
  bool matchesLibraryVariant(String? variant) =>
      _swiftPm.matchesLibraryVariant(variant);
  @override
  String transformPlist(
    String xml, {
    String? sdkName,
    XcodeBuildMetadata? build,
  }) => IosPlistMetadata.overwrite(
    xml,
    platform: target.buildPlatform,
    sdkName: sdkName,
    build: build,
  );
  @override
  String get sanitizerRuntimeLibrary => 'libclang_rt.iossim.a';
  @override
  String get workspaceSuffix => _swiftPm.workspaceSuffix;
  @override
  String get binaryArtifactDirectory => _swiftPm.binaryArtifactDirectory;
}
