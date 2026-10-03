import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';

final class SwiftPmCheckoutContainment {
  const SwiftPmCheckoutContainment(this.fileSystem);
  final SwiftPmArtifactFileSystem fileSystem;

  void validateDestination(String root, String destination) {
    if (!p.isWithin(root, destination)) {
      throw FlutterBuildError(
        'Symlink destination escapes SwiftPM checkout: $destination',
        isSecurityFailure: true,
      );
    }
    validateTarget(root, p.dirname(destination));
    if (fileSystem.directory(destination).existsSync() ||
        fileSystem.file(destination).existsSync()) {
      validateTarget(root, destination);
    }
  }

  void validateTarget(String root, String target) {
    if (!p.equals(root, target) && !p.isWithin(root, target)) {
      throw FlutterBuildError(
        'Symlink target escapes SwiftPM checkout: $target',
        isSecurityFailure: true,
      );
    }
    final canonicalRoot = fileSystem.directory(root).resolveSymbolicLinksSync();
    var existing = target;
    while (fileSystem.typeSync(existing, followLinks: false) ==
            FileSystemEntityType.notFound &&
        existing != root) {
      existing = p.dirname(existing);
    }
    final canonical = fileSystem.directory(existing).resolveSymbolicLinksSync();
    if (!p.equals(canonicalRoot, canonical) &&
        !p.isWithin(canonicalRoot, canonical)) {
      throw FlutterBuildError(
        'Symlink path escapes SwiftPM checkout through an existing link: $target',
        isSecurityFailure: true,
      );
    }
  }
}
