import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_lexer.dart';

final class SwiftPmPackageMetadata {
  SwiftPmPackageMetadata({required this.fileSystem});
  final SwiftPmArtifactFileSystem fileSystem;
  Future<Map<String, String>> packageIdentitiesByDirectory(String root) async {
    final identities = <String, String>{};
    final pending = <String>[root];
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final directory = p.normalize(pending.removeLast());
      if (!visited.add(directory)) continue;
      final manifestFile = fileSystem.file(p.join(directory, 'Package.swift'));
      if (!manifestFile.existsSync()) continue;
      final manifest = await manifestFile.readAsString();
      for (final call in SwiftPmManifestLexer.swiftCalls(
        manifest,
        '.package',
      )) {
        final path = SwiftPmManifestLexer.namedString(call.text, 'path');
        if (path == null) continue;
        final dependencyDirectory = p.normalize(
          p.isAbsolute(path) ? path : p.join(directory, path),
        );
        final dependencyManifest = fileSystem.file(
          p.join(dependencyDirectory, 'Package.swift'),
        );
        final identity =
            SwiftPmManifestLexer.namedString(call.text, 'name') ??
            (dependencyManifest.existsSync()
                ? RegExp(r'Package\s*\(\s*name\s*:\s*"([^"]+)"')
                      .firstMatch(await dependencyManifest.readAsString())
                      ?.group(1)
                : null);
        if (identity != null) identities[dependencyDirectory] = identity;
        pending.add(dependencyDirectory);
      }
    }
    return identities;
  }
}
