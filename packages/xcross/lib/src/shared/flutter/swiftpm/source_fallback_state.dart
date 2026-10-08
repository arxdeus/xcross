import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';

@internal
@immutable
final class SwiftPmSourceFallbackState {
  const SwiftPmSourceFallbackState({
    this.consumedProducts = const {},
    this.swiftModules = const {},
  });

  static const String fileName = '.xcross-source-fallback.json';

  final Map<String, Set<String>> consumedProducts;
  final Map<String, List<String>> swiftModules;

  static String path(String outputDir) => p.join(outputDir, fileName);

  static Future<SwiftPmSourceFallbackState> read(
    SwiftPmArtifactFileSystem fileSystem,
    String outputDir,
  ) async {
    final file = fileSystem.file(path(outputDir));
    if (!file.existsSync()) return const SwiftPmSourceFallbackState();
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return const SwiftPmSourceFallbackState();
      }
      return SwiftPmSourceFallbackState(
        consumedProducts: {
          for (final MapEntry(:key, :value)
              in ((decoded['consumedProducts'] as Map?) ?? const {}).entries)
            key as String: {...(value as List).cast<String>()},
        },
        swiftModules: {
          for (final MapEntry(:key, :value)
              in ((decoded['swiftModules'] as Map?) ?? const {}).entries)
            key as String: (value as List).cast<String>(),
        },
      );
    } on Object {
      return const SwiftPmSourceFallbackState();
    }
  }

  Future<void> write(SwiftPmFilesystem filesystem, String outputDir) async {
    await filesystem.artifactFileSystem
        .directory(outputDir)
        .create(recursive: true);
    await filesystem.writeStable(path(outputDir), encode());
  }

  String encode() => jsonEncode({
    'consumedProducts': {
      for (final key in consumedProducts.keys.toList()..sort())
        key: consumedProducts[key]!.toList()..sort(),
    },
    'swiftModules': {
      for (final key in swiftModules.keys.toList()..sort())
        key: swiftModules[key],
    },
  });
}
