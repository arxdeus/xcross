import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/errors.dart';

@internal
abstract interface class FlutterTargetBuildPolicy<
  T extends PlatformHostInterface
> {
  IosTarget<T> get target;
  String outputDirectory(String projectRoot);
  String buildDirectory(String projectRoot, String name);
  String get engineArtifact;
  List<String> get engineSliceIdentifiers;
  String selectEngineSlice(String xcframework);
  bool matchesLibraryVariant(String? variant);
  String transformPlist(String xml, {String? sdkName});
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
