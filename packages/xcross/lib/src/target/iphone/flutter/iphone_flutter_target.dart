import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';
import 'package:xcross/src/target/shared/flutter/ios_plist_metadata.dart';

final class IPhoneFlutterTarget<T extends PlatformHostInterface>
    implements FlutterTargetBuildPolicy<T> {
  const IPhoneFlutterTarget(this.target);
  @override
  final IPhoneTargetInterface<T> target;
  @override
  String outputDirectory(String projectRoot) =>
      target.host.paths.context.join(projectRoot, 'build', 'xcross-ios');
  @override
  String buildDirectory(String projectRoot, String name) =>
      target.host.paths.context.join(projectRoot, 'build', name);
  @override
  String get engineArtifact => 'ios';
  @override
  List<String> get engineSliceIdentifiers => const ['ios-arm64'];
  @override
  String selectEngineSlice(String xcframework) => selectFlutterEngineSlice(
    xcframework,
    engineSliceIdentifiers,
    paths: target.host.paths.context,
    fileSystem: target.host.fileSystem,
  );
  @override
  bool matchesLibraryVariant(String? variant) => variant == null;
  @override
  String transformPlist(String xml, {String? sdkName}) =>
      IosPlistMetadata.fillMissing(
        xml,
        platform: target.buildPlatform,
        sdkName: sdkName,
      );
  @override
  String get sanitizerRuntimeLibrary => 'libclang_rt.ios.a';
  @override
  String get workspaceSuffix => '';
  @override
  String get binaryArtifactDirectory => 'binary-artifacts-v1';
}
