import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_tree.dart';

@internal
final class SwiftPmBinaryArtifactEntry {
  const SwiftPmBinaryArtifactEntry({
    required this.archiveChecksum,
    required this.targetName,
    required this.artifactPath,
  });

  final String archiveChecksum;
  final String targetName;
  final String artifactPath;
}

@internal
final class SwiftPmBinaryArtifactStore {
  SwiftPmBinaryArtifactStore(
    this.root, {
    required this.host,
    required this.fileSystem,
    required this.publicationCoordinator,
  });
  final PlatformHostInterface host;
  final SwiftPmPublicationCoordinator publicationCoordinator;
  final SwiftPmArtifactFileSystem fileSystem;

  final String root;
  late final SwiftPmArtifactTree _tree = SwiftPmArtifactTree(fileSystem);

  String archivePath(String checksum) =>
      p.join(root, 'archives', '${_checksumComponent(checksum)}.zip');

  String targetRoot(String checksum, String targetName) => p.join(
    root,
    'targets',
    _checksumComponent(checksum),
    _component(targetName, 'target name'),
  );

  Future<File> publishArchive(
    File stagingArchive,
    String checksum, {
    int maximumBytes = 536870912,
  }) async {
    final expected = _checksumComponent(checksum);
    final destination = fileSystem.file(archivePath(expected));
    await destination.parent.create(recursive: true);
    return _withPublicationLock(destination.path, () async {
      if (destination.existsSync()) {
        await _verifyArchive(destination, expected);
        return destination;
      }

      final stagingDirectory = await destination.parent.createTemp(
        '.${p.basename(destination.path)}.staging-',
      );
      final staging = fileSystem.file(
        p.join(stagingDirectory.path, 'archive.zip'),
      );
      try {
        await staging.create(exclusive: true);
        final output = await staging.open(mode: FileMode.writeOnly);
        try {
          var copiedBytes = 0;
          await for (final chunk in stagingArchive.openRead()) {
            copiedBytes += chunk.length;
            if (copiedBytes > maximumBytes) {
              throw FlutterBuildError(
                'SwiftPM binary artifact exceeds compressed archive byte limit',
              );
            }
            await output.writeFrom(chunk);
          }
          await output.flush();
        } finally {
          await output.close();
        }
        await _verifyArchive(staging, expected);
        if (destination.existsSync()) {
          await _verifyArchive(destination, expected);
          return destination;
        }
        return await staging.rename(destination.path);
      } finally {
        if (stagingDirectory.existsSync()) {
          await stagingDirectory.delete(recursive: true);
        }
      }
    });
  }

  Future<List<int>> readVerifiedArchiveBytes(
    String checksum, {
    int? maximumBytes,
  }) {
    final expected = _checksumComponent(checksum);
    final path = archivePath(expected);
    return _withPublicationLock(path, () async {
      final file = fileSystem.file(path);
      final bytes = await file.readAsBytes();
      if (maximumBytes != null && bytes.length > maximumBytes) {
        throw FlutterBuildError(
          'SwiftPM binary artifact exceeds compressed archive byte limit',
        );
      }
      final actual = sha256.convert(bytes).toString();
      if (actual != expected) {
        throw FlutterBuildError(
          'SwiftPM binary artifact checksum mismatch: expected $expected, got $actual',
          isSecurityFailure: true,
        );
      }
      return bytes;
    });
  }

  Future<SwiftPmBinaryArtifactEntry> publishTarget({
    required String checksum,
    required String targetName,
    required Directory stagingRoot,
    required String artifactDirectoryName,
    required Map<String, Object?> metadata,
  }) async {
    final safeChecksum = _checksumComponent(checksum);
    final safeTarget = _component(targetName, 'target name');
    await _verifyArchive(
      fileSystem.file(archivePath(safeChecksum)),
      safeChecksum,
    );
    final safeArtifact = _component(
      artifactDirectoryName,
      'artifact directory name',
    );
    final destination = fileSystem.directory(
      targetRoot(safeChecksum, safeTarget),
    );
    final existing = await findCompleteTarget(safeChecksum, safeTarget);
    if (existing != null) return existing;

    await destination.parent.create(recursive: true);
    if (fileSystem.typeSync(stagingRoot.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FlutterBuildError(
        'SwiftPM binary artifact staging root must be a real directory',
      );
    }
    return _withPublicationLock(destination.path, () async {
      final winner = await findCompleteTarget(safeChecksum, safeTarget);
      if (winner != null) return winner;
      if (fileSystem.typeSync(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await _preserveIncomplete(destination.path);
      }

      final staging = await destination.parent.createTemp(
        '.$safeTarget.staging-',
      );
      try {
        await _tree.copyDirectoryContents(stagingRoot, staging);
        final artifactPath = p.join(staging.path, safeArtifact);
        if (fileSystem.typeSync(artifactPath, followLinks: false) !=
            FileSystemEntityType.directory) {
          throw FlutterBuildError(
            'SwiftPM binary artifact root must be a real directory: '
            '$safeArtifact',
          );
        }
        if (await _tree.containsLink(staging)) {
          throw FlutterBuildError(
            'SwiftPM binary artifact target trees must not contain links or reparse points',
            isSecurityFailure: true,
          );
        }
        final completeMetadata = <String, Object?>{
          ...metadata,
          'archiveChecksum': safeChecksum,
          'verifiedArchiveChecksum': safeChecksum,
          'targetName': safeTarget,
          'artifactDirectoryName': safeArtifact,
          'treeDigest': await _tree.treeDigest(
            fileSystem.directory(artifactPath),
          ),
        };
        await fileSystem
            .file(p.join(staging.path, 'metadata.json'))
            .writeAsString(jsonEncode(completeMetadata), flush: true);
        await fileSystem
            .file(p.join(staging.path, '.complete'))
            .writeAsString('', flush: true);
        if (fileSystem.typeSync(destination.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          final racedWinner = await findCompleteTarget(
            safeChecksum,
            safeTarget,
          );
          if (racedWinner != null) return racedWinner;
          throw FlutterBuildError(
            'SwiftPM binary artifact destination changed during publication '
            'for $safeTarget',
          );
        }
        await staging.rename(destination.path);
        final published = await findCompleteTarget(safeChecksum, safeTarget);
        if (published == null) {
          throw FlutterBuildError(
            'SwiftPM binary artifact publication is incomplete for $safeTarget',
          );
        }
        return published;
      } finally {
        if (staging.existsSync()) await staging.delete(recursive: true);
      }
    });
  }

  Future<SwiftPmBinaryArtifactEntry?> findCompleteTarget(
    String checksum,
    String targetName,
  ) async {
    final safeChecksum = _checksumComponent(checksum);
    final safeTarget = _component(targetName, 'target name');
    final target = fileSystem.directory(targetRoot(safeChecksum, safeTarget));
    if (fileSystem.typeSync(target.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await _tree.containsLink(target) ||
        fileSystem.typeSync(
              p.join(target.path, '.complete'),
              followLinks: false,
            ) !=
            FileSystemEntityType.file) {
      return null;
    }
    try {
      final decoded = jsonDecode(
        await fileSystem
            .file(p.join(target.path, 'metadata.json'))
            .readAsString(),
      );
      if (decoded is! Map<String, dynamic> ||
          decoded['archiveChecksum'] != safeChecksum ||
          decoded['verifiedArchiveChecksum'] != safeChecksum ||
          decoded['targetName'] != safeTarget ||
          decoded['artifactDirectoryName'] is! String ||
          decoded['treeDigest'] is! String) {
        return null;
      }
      await _verifyArchive(
        fileSystem.file(archivePath(safeChecksum)),
        safeChecksum,
      );
      final artifactName = decoded['artifactDirectoryName'] as String;
      if (!_isSafeComponent(artifactName)) return null;
      final artifactPath = p.join(target.path, artifactName);
      if (fileSystem.typeSync(artifactPath, followLinks: false) !=
              FileSystemEntityType.directory ||
          await _tree.treeDigest(fileSystem.directory(artifactPath)) !=
              decoded['treeDigest']) {
        return null;
      }
      return SwiftPmBinaryArtifactEntry(
        archiveChecksum: safeChecksum,
        targetName: safeTarget,
        artifactPath: artifactPath,
      );
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  static String _checksumComponent(String value) =>
      _component(value, 'checksum').toLowerCase();

  static String _component(String value, String label) {
    if (!_isSafeComponent(value)) {
      throw ArgumentError.value(
        value,
        label,
        'must be one safe path component',
      );
    }
    return value;
  }

  static bool _isSafeComponent(String value) {
    if (value.isEmpty ||
        value == '.' ||
        value == '..' ||
        value.contains('/') ||
        value.contains(r'\') ||
        value.endsWith('.') ||
        value.endsWith(' ')) {
      return false;
    }
    for (final code in value.codeUnits) {
      if (code < 0x20 || code > 0x7e) return false;
    }
    if (value.contains(RegExp('[<>:"|?*]'))) return false;
    final stem = value.split('.').first.toLowerCase();
    return !RegExp(
      r'^(con|prn|aux|nul|clock\$|com[1-9]|lpt[1-9])$',
    ).hasMatch(stem);
  }

  static Future<void> _verifyArchive(File file, String checksum) async {
    final actual = await sha256.bind(file.openRead()).first;
    if (actual.toString().toLowerCase() != checksum.toLowerCase()) {
      throw FlutterBuildError(
        'SwiftPM binary artifact checksum mismatch: expected $checksum, '
        'got $actual',
        isSecurityFailure: true,
      );
    }
  }

  Future<void> _preserveIncomplete(String destinationPath) async {
    final parent = fileSystem.directory(p.dirname(destinationPath));
    final quarantine = await parent.createTemp(
      '.${p.basename(destinationPath)}.incomplete-',
    );
    final preservedPath = p.join(quarantine.path, 'entry');
    switch (fileSystem.typeSync(destinationPath, followLinks: false)) {
      case FileSystemEntityType.directory:
        await fileSystem.directory(destinationPath).rename(preservedPath);
      case FileSystemEntityType.file:
        await fileSystem.file(destinationPath).rename(preservedPath);
      case FileSystemEntityType.link:
        await fileSystem.link(destinationPath).rename(preservedPath);
      case FileSystemEntityType.notFound:
      case FileSystemEntityType.pipe:
      case FileSystemEntityType.unixDomainSock:
        throw FlutterBuildError(
          'Cannot preserve incomplete SwiftPM binary artifact destination',
        );
    }
  }

  Future<T> _withPublicationLock<T>(
    String destinationPath,
    Future<T> Function() action,
  ) => publicationCoordinator.run(destinationPath, action);
}
