import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_tree.dart';

@internal
final class SwiftPmOfflineArtifactPublisher {
  SwiftPmOfflineArtifactPublisher({
    required this.fileSystem,
    required this.publicationCoordinator,
  }) : _tree = SwiftPmArtifactTree(fileSystem);

  final SwiftPmArtifactFileSystem fileSystem;
  final SwiftPmPublicationCoordinator publicationCoordinator;
  final SwiftPmArtifactTree _tree;

  Future<String> publish({
    required Directory stagingRoot,
    required String destination,
    required String artifactDirectoryName,
  }) async {
    if (!SwiftPmArtifactTree.isSafeComponent(artifactDirectoryName)) {
      throw ArgumentError.value(artifactDirectoryName, 'artifactDirectoryName');
    }
    final source = fileSystem.directory(
      p.join(stagingRoot.path, artifactDirectoryName),
    );
    if (fileSystem.typeSync(source.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await fileSystem.isLinkOrReparsePoint(source.path) ||
        await _tree.containsLink(stagingRoot)) {
      throw FlutterBuildError(
        'SwiftPM offline binary artifact must contain a real, link-free tree',
        isSecurityFailure: true,
      );
    }
    final digest = await _tree.treeDigest(source);
    final publishedPath = await publicationCoordinator.run(
      destination,
      () async {
        final artifactPath = p.join(destination, artifactDirectoryName);
        if (fileSystem.typeSync(destination, followLinks: false) !=
            FileSystemEntityType.notFound) {
          if (await _reusable(destination, artifactDirectoryName, digest)) {
            return artifactPath;
          }
          throw FileSystemException(
            'Refusing to replace an unowned or changed offline binary artifact',
            destination,
          );
        }
        final parent = fileSystem.directory(p.dirname(destination));
        await parent.create(recursive: true);
        final temporary = await parent.createTemp('.xcross-offline-');
        try {
          await _tree.copyDirectoryContents(stagingRoot, temporary);
          final copied = fileSystem.directory(
            p.join(temporary.path, artifactDirectoryName),
          );
          if (await _tree.treeDigest(copied) != digest) {
            throw FileSystemException(
              'SwiftPM offline binary artifact changed during publication',
              source.path,
            );
          }
          for (final name in ['metadata.json', '.complete']) {
            final marker = fileSystem.file(p.join(temporary.path, name));
            if (marker.existsSync()) await marker.delete();
          }
          await fileSystem
              .file(p.join(temporary.path, '.xcross-offline.json'))
              .writeAsString(
                jsonEncode({
                  'provenance': 'unverified-extracted-tree',
                  'artifactDirectoryName': artifactDirectoryName,
                  'treeDigest': digest,
                }),
                flush: true,
              );
          await temporary.rename(destination);
          return artifactPath;
        } finally {
          if (temporary.existsSync()) await temporary.delete(recursive: true);
        }
      },
    );
    return publishedPath;
  }

  Future<bool> isPublishedArtifact(String artifactPath) async {
    final artifactName = p.basename(artifactPath);
    if (!SwiftPmArtifactTree.isSafeComponent(artifactName)) return false;
    final root = p.dirname(artifactPath);
    try {
      final metadata = jsonDecode(
        await fileSystem
            .file(p.join(root, '.xcross-offline.json'))
            .readAsString(),
      );
      if (metadata is! Map<String, dynamic> ||
          metadata['treeDigest'] is! String) {
        return false;
      }
      return await _reusable(
        root,
        artifactName,
        metadata['treeDigest'] as String,
      );
    } on FormatException {
      return false;
    } on FileSystemException {
      return false;
    } on FlutterBuildError {
      return false;
    }
  }

  Future<bool> _reusable(
    String root,
    String artifactName,
    String digest,
  ) async {
    if (fileSystem.typeSync(root, followLinks: false) !=
            FileSystemEntityType.directory ||
        await fileSystem.isLinkOrReparsePoint(root) ||
        await _tree.containsLink(fileSystem.directory(root))) {
      return false;
    }
    try {
      final metadata = jsonDecode(
        await fileSystem
            .file(p.join(root, '.xcross-offline.json'))
            .readAsString(),
      );
      return metadata is Map<String, dynamic> &&
          metadata['provenance'] == 'unverified-extracted-tree' &&
          metadata['artifactDirectoryName'] == artifactName &&
          metadata['treeDigest'] == digest &&
          await _tree.treeDigest(
                fileSystem.directory(p.join(root, artifactName)),
              ) ==
              digest;
    } on FormatException {
      return false;
    } on FileSystemException {
      return false;
    }
  }
}
