import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_containment.dart';

final class SwiftPmCheckoutStampValidator {
  const SwiftPmCheckoutStampValidator({required this.fileSystem});
  final SwiftPmArtifactFileSystem fileSystem;
  static const _stampKindDirectory = 'directory';
  static const _stampKindHardLink = 'hardlink';
  static const _stampKindForwarder = 'forwarder';
  static const _stampKindSymlink = 'symlink';
  bool materializedLinksIntact(
    File stamp,
    String fingerprint, {
    required String root,
  }) {
    if (!stamp.existsSync()) return false;
    final Object? decoded;
    try {
      decoded = jsonDecode(stamp.readAsStringSync());
    } on FormatException {
      return false;
    }
    if (decoded is! Map ||
        decoded['version'] != 3 ||
        decoded['fingerprint'] != fingerprint) {
      return false;
    }
    final links = decoded['links'];
    if (links is! List) return false;
    for (final entry in links) {
      if (entry is! Map) return false;
      final path = entry['path'];
      final kind = entry['kind'];
      final target = entry['target'];
      final directory = entry['directory'];
      if (path is! String || kind is! String || target is! String) return false;
      if (kind == _stampKindSymlink && !entry.containsKey('directory')) {
        return false;
      }
      if (directory != null && directory is! bool) return false;
      try {
        final containment = SwiftPmCheckoutContainment(fileSystem);
        containment.validateDestination(root, path);
        if (kind == _stampKindDirectory) {
          containment.validateTarget(root, target);
        } else if (kind == _stampKindSymlink || kind == _stampKindHardLink) {
          containment.validateLinkTarget(root, path, target);
        } else if (kind == _stampKindForwarder) {
          final include = RegExp(
            r'^#include "([^"\n]+)"\n$',
          ).firstMatch(target);
          if (include == null) return false;
          containment.validateLinkTarget(root, path, include[1]!);
        }
      } on FlutterBuildError {
        return false;
      } on FileSystemException {
        return false;
      }
      if (!linkIntact(path, kind, target, directory: directory as bool?)) {
        return false;
      }
    }
    return true;
  }

  bool linkIntact(String path, String kind, String target, {bool? directory}) {
    switch (kind) {
      case _stampKindSymlink:
        if (fileSystem.typeSync(path, followLinks: false) !=
                FileSystemEntityType.link ||
            fileSystem.link(path).targetSync() != target) {
          return false;
        }
        final resolved = p.normalize(p.absolute(p.dirname(path), target));
        if (fileSystem.directory(resolved).existsSync()) {
          return directory != false && fileSystem.directory(path).existsSync();
        }
        if (fileSystem.file(resolved).existsSync()) {
          return directory != true && fileSystem.file(path).existsSync();
        }
        return directory == null;
      case _stampKindForwarder:
        final file = fileSystem.file(path);
        return fileSystem.typeSync(path, followLinks: false) !=
                FileSystemEntityType.link &&
            file.existsSync() &&
            file.readAsStringSync() == target;
      case _stampKindHardLink:
        final file = fileSystem.file(path);
        if (fileSystem.typeSync(path, followLinks: false) ==
                FileSystemEntityType.link ||
            !file.existsSync()) {
          return false;
        }
        final placeholder = utf8.encode(target);
        return file.lengthSync() != placeholder.length ||
            !sameBytes(file.readAsBytesSync(), placeholder);
      case _stampKindDirectory:
        return fileSystem.typeSync(path, followLinks: false) !=
                FileSystemEntityType.link &&
            fileSystem.directory(path).existsSync();
      default:
        return false;
    }
  }

  static bool sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
