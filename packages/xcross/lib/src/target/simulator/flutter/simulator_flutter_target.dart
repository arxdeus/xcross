import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';
import 'package:xcross/src/target/shared/flutter/ios_plist_metadata.dart';

final class SimulatorFlutterTarget<T extends PlatformHostInterface>
    implements FlutterTargetBuildPolicy<T> {
  const SimulatorFlutterTarget(this.target);
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
  List<String> get engineSliceIdentifiers => const [
    'ios-arm64_x86_64-simulator',
    'ios-arm64-simulator',
  ];
  @override
  String selectEngineSlice(String xcframework) => selectFlutterEngineSlice(
    xcframework,
    engineSliceIdentifiers,
    paths: target.host.paths.context,
    fileSystem: target.host.fileSystem,
  );
  @override
  bool matchesLibraryVariant(String? variant) => variant == 'simulator';
  @override
  String transformPlist(String xml, {String? sdkName}) =>
      IosPlistMetadata.overwrite(
        xml,
        platform: target.buildPlatform,
        sdkName: sdkName,
      );
  @override
  String get sanitizerRuntimeLibrary => 'libclang_rt.iossim.a';
  @override
  String get workspaceSuffix => '-simulator';
  @override
  String get binaryArtifactDirectory => 'binary-artifacts-simulator-v1';
}
