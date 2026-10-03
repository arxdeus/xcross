import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';

final class SwiftPmArtifactTree {
  const SwiftPmArtifactTree(this.fileSystem);
  final SwiftPmArtifactFileSystem fileSystem;
  static bool isSafeComponent(String value) {
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

  Future<void> copyDirectoryContents(
    Directory source,
    Directory destination,
  ) async {
    final names = <String>{};
    await for (final entity in _ioDirectory(
      source.path,
    ).list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (!isSafeComponent(name) || !names.add(name.toLowerCase())) {
        throw FlutterBuildError(
          'SwiftPM binary artifact target tree contains an unsafe or case-fold-colliding path',
          isSecurityFailure: true,
        );
      }
      final target = p.join(destination.path, name);
      if (await _isLinkOrReparsePoint(entity.path)) {
        throw FlutterBuildError(
          'SwiftPM binary artifact target trees must not contain links or reparse points',
          isSecurityFailure: true,
        );
      }
      if (entity is File) {
        await entity.copy(_ioPath(target));
      } else if (entity is Directory) {
        final child = await _ioDirectory(target).create();
        await copyDirectoryContents(entity, child);
      } else {
        throw FlutterBuildError(
          'SwiftPM binary artifact target trees must not contain symlinks',
        );
      }
    }
  }

  Future<bool> containsLink(Directory root) async {
    await for (final entity in _ioDirectory(
      root.path,
    ).list(recursive: true, followLinks: false)) {
      if (await _isLinkOrReparsePoint(entity.path)) return true;
    }
    return false;
  }

  Directory _ioDirectory(String path) => fileSystem.directory(_ioPath(path));

  String _ioPath(String path) => fileSystem.directory(path).path;

  Future<bool> _isLinkOrReparsePoint(String path) =>
      fileSystem.isLinkOrReparsePoint(path);

  Future<String> treeDigest(Directory root) async {
    final rootPath = _ioPath(root.path);
    final entries = _ioDirectory(rootPath).listSync(
      recursive: true,
      followLinks: false,
    )..sort((left, right) => left.path.compareTo(right.path));

    Digest? digest;
    final input = sha256.startChunkedConversion(
      ChunkedConversionSink.withCallback((digests) => digest = digests.single),
    );

    void addFrame(String value) {
      input.add(utf8.encode(value));
      input.add(const [0]);
    }

    addFrame('xcross-swiftpm-target-tree-v1');
    final foldedPaths = <String>{};
    for (final entity in entries) {
      if (await _isLinkOrReparsePoint(entity.path)) {
        throw FlutterBuildError(
          'SwiftPM binary artifact target trees must not contain links or reparse points',
          isSecurityFailure: true,
        );
      }
      final relative = p
          .relative(entity.path, from: rootPath)
          .replaceAll(r'\', '/');

      if (!foldedPaths.add(relative.toLowerCase())) {
        throw FlutterBuildError(
          'SwiftPM binary artifact target tree contains an unsafe or case-fold-colliding path',
          isSecurityFailure: true,
        );
      }
      final type = fileSystem.typeSync(entity.path, followLinks: false);
      addFrame(type.toString());
      addFrame(relative);
      switch (type) {
        case FileSystemEntityType.file:
          final file = fileSystem.file(entity.path);
          addFrame((await file.length()).toString());
          await for (final chunk in file.openRead()) {
            input.add(chunk);
          }
        case FileSystemEntityType.directory:
          addFrame('0');
        default:
          throw FlutterBuildError(
            'SwiftPM binary artifact target trees contain an unsupported entry type',
            isSecurityFailure: true,
          );
      }
      input.add(const [0]);
    }
    input.close();
    return digest.toString();
  }
}
