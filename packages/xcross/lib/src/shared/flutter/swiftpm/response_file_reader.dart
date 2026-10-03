import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/response_arguments.dart';
final class SwiftPmResponseFileReader {
SwiftPmResponseFileReader({required this.fileSystem});
final SwiftPmArtifactFileSystem fileSystem;
  Set<String>? referencedResponseArguments(
    String manifest,
    String scratchPath,
  ) {
    final cache = p.absolute(p.join(scratchPath, '.xcross-response'));
    final arguments = <String>{};
    for (final line in manifest.split('\n')) {
      final decoded = SwiftPmResponseArguments.decodeLlbuildArguments(line);
      if (decoded == null) continue;
      for (final reference in decoded.whereType<String>().where((value) => value.startsWith('@')).map((value) => value.substring(1))) {
        final path = p.normalize(p.absolute(reference));
        if (!p.isWithin(cache, path) ||
            fileSystem.typeSync(path,followLinks:false)==FileSystemEntityType.link ||
            !RegExp(r'^[a-f0-9]{64}\.rsp$').hasMatch(p.basename(path))) {
          continue;
        }
        try {
          arguments.addAll(fileSystem.file(path).readAsLinesSync());
        } on FileSystemException {
          return null;
        }
      }
    }
    return arguments;
  }

}
