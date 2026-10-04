import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmBinaryLayout<T extends PlatformHostInterface> {
  SwiftPmBinaryLayout({
    required this.artifactFileSystem,
    required this.targetPolicy,
  });
  final SwiftPmArtifactFileSystem artifactFileSystem;
  final FlutterTargetBuildPolicy<T> targetPolicy;
  Set<String> libraryIdentifiers(Directory artifact) {
    final fallback = {
      for (final id in targetPolicy.engineSliceIdentifiers)
        if (artifactFileSystem
            .directory(p.join(artifact.path, id))
            .existsSync())
          id,
    };
    final info = artifactFileSystem.file(p.join(artifact.path, 'Info.plist'));
    try {
      final plist = PropertyListSerialization.propertyListWithString(
        info.readAsStringSync(),
      );
      if (plist is! Map || plist['AvailableLibraries'] is! List) {
        return fallback;
      }
      return {
        for (final library in plist['AvailableLibraries'] as List)
          if (library is Map &&
              library['SupportedPlatform'] == 'ios' &&
              targetPolicy.matchesLibraryVariant(
                library['SupportedPlatformVariant'] as String?,
              ) &&
              library['SupportedArchitectures'] is List &&
              (library['SupportedArchitectures'] as List).contains('arm64') &&
              library['LibraryIdentifier'] is String)
            library['LibraryIdentifier'] as String,
      };
    } on Object {
      return fallback;
    }
  }

  Future<bool> hasCompleteSwiftPmArtifact(Directory artifact) async {
    final info = artifactFileSystem.file(p.join(artifact.path, 'Info.plist'));
    if (!info.existsSync()) return false;
    try {
      final value = PropertyListSerialization.propertyListWithString(
        await info.readAsString(),
      );
      if (value is! Map) return false;
      final libraries = value['AvailableLibraries'];
      if (libraries is! List) return false;
      for (final value in libraries) {
        if (value is! Map ||
            value['SupportedPlatform'] != 'ios' ||
            !targetPolicy.matchesLibraryVariant(
              value['SupportedPlatformVariant'] as String?,
            )) {
          continue;
        }
        final architectures = value['SupportedArchitectures'];
        final identifier = value['LibraryIdentifier'];
        final libraryPath = value['LibraryPath'];
        if (architectures is! List ||
            !architectures.contains('arm64') ||
            identifier is! String ||
            identifier.isEmpty ||
            libraryPath is! String ||
            libraryPath.isEmpty) {
          continue;
        }
        if (artifactFileSystem.typeSync(
              p.join(artifact.path, identifier, libraryPath),
            ) !=
            FileSystemEntityType.notFound) {
          return true;
        }
      }
    } on Object {
      return false;
    }
    return false;
  }
}
