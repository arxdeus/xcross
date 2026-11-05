import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/target/shared/flutter/xcode_build_metadata.dart';

@internal
abstract interface class FlutterTargetBuildPolicy<
  T extends PlatformHostInterface
> {
  IosTarget<T> get target;
  String outputDirectory(String projectRoot);
  String buildDirectory(String projectRoot, String name);
  String get engineArtifact;

  /// Whether this target runs ahead-of-time compiled Flutter code. Flutter's
  /// simulator engines are JIT-only in every build mode.
  bool get supportsPrecompiledModes;

  /// Whether the build embeds the project's entitlements in the ad-hoc
  /// signature. Devices need them carried to the re-signer; the simulator
  /// refuses to launch an ad-hoc binary whose signature carries restricted
  /// entitlements (`aps-environment`, associated domains), as with Apple's
  /// own `codesign -s -`, which is why Xcode keeps them out of it there.
  bool get embedsEntitlements;
  List<String> get engineSliceIdentifiers;
  String selectEngineSlice(String xcframework);
  bool matchesLibraryVariant(String? variant);

  /// Stamps the target's platform keys, plus the Xcode/SDK provenance keys
  /// from [build] when known (see [XcodeBuildMetadata.load]).
  String transformPlist(
    String xml, {
    String? sdkName,
    XcodeBuildMetadata? build,
  });
  String get sanitizerRuntimeLibrary;
  String get workspaceSuffix;
  String get binaryArtifactDirectory;
}

@internal
String selectFlutterEngineSlice(
  String xcframework,
  Iterable<String> identifiers, {
  required p.Context paths,
  required HostFileSystemInterface fileSystem,
}) {
  for (final identifier in identifiers) {
    final slice = paths.join(xcframework, identifier);
    if (fileSystem
        .directory(paths.join(slice, 'Flutter.framework'))
        .existsSync()) {
      return slice;
    }
  }
  throw FlutterBuildError('Flutter ARM64 engine slice missing in $xcframework');
}
