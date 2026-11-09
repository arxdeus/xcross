import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/target/iphone/swiftpm/iphone_swiftpm_target.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';
import 'package:xcross/src/target/shared/flutter/ios_plist_metadata.dart';
import 'package:xcross/src/target/shared/flutter/xcode_build_metadata.dart';

@internal
final class IPhoneFlutterTarget<T extends PlatformHostInterface>
    implements FlutterTargetBuildPolicy<T> {
  const IPhoneFlutterTarget(this.target);

  /// The SwiftPM half of this policy, the single source of the workspace
  /// suffix (part of the SwiftPM cache key), slices and artifact store.
  IPhoneSwiftPmTarget<T> get _swiftPm => IPhoneSwiftPmTarget(target);

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
  bool get supportsPrecompiledModes => true;
  @override
  bool get embedsEntitlements => true;
  @override
  List<String> get engineSliceIdentifiers => const ['ios-arm64'];
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
  String get sanitizerRuntimeLibrary => 'libclang_rt.ios.a';
  @override
  String get workspaceSuffix => _swiftPm.workspaceSuffix;
  @override
  String get binaryArtifactDirectory => _swiftPm.binaryArtifactDirectory;
}
