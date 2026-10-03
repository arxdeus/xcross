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
    final canonicalRoot = fileSystem.directory(root).resolveSymbolicLinksSync();
    final activeLinks = <String>{};
    var hops = 0;
    Never reject(String path) => throw FlutterBuildError(
      'Symlink path escapes SwiftPM checkout or cycles: $path',
      isSecurityFailure: true,
    );
    void contained(String path) {
      if (!p.equals(root, path) && !p.isWithin(root, path)) reject(path);
    }

    String walk(String start, Iterable<String> components) {
      var current = start;
      for (final component in components) {
        if (component == '.' || component.isEmpty) continue;
        current = p.normalize(p.join(current, component));
        contained(current);
        final type = fileSystem.typeSync(current, followLinks: false);
        if (type == FileSystemEntityType.link) {
          if (++hops > 256 || !activeLinks.add(current)) reject(current);
          final link = current;
          final destination = fileSystem.link(link).targetSync();
          if (p.isAbsolute(destination)) {
            if (!destination.startsWith('$root${p.separator}')) {
              if (!p.equals(root, destination)) reject(destination);
            }
            current = walk(
              root,
              p.equals(root, destination)
                  ? const <String>[]
                  : p.split(destination.substring(root.length + 1)),
            );
          } else {
            current = walk(p.dirname(link), p.split(destination));
          }
          activeLinks.remove(link);
        } else if (type != FileSystemEntityType.notFound) {
          final canonical = fileSystem
              .directory(current)
              .resolveSymbolicLinksSync();
          if (!p.equals(canonicalRoot, canonical) &&
              !p.isWithin(canonicalRoot, canonical)) {
            reject(current);
          }
        }
      }
      return current;
    }

    contained(target);
    walk(root, p.split(p.relative(target, from: root)));
  }
}
