import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'package:xcross/src/flutter/errors.dart';

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

final class SwiftPmBinaryArtifactStore {
  SwiftPmBinaryArtifactStore(this.root);

  static final Map<String, Future<void>> _localPublicationTails = {};

  final String root;

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
    final destination = File(archivePath(expected));
    await destination.parent.create(recursive: true);
    return _withPublicationLock(destination.path, () async {
      if (destination.existsSync()) {
        await _verifyArchive(destination, expected);
        return destination;
      }

      final stagingDirectory = await destination.parent.createTemp(
        '.${p.basename(destination.path)}.staging-',
      );
      final staging = File(p.join(stagingDirectory.path, 'archive.zip'));
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
      final file = File(path);
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
    final safeArtifact = _component(
      artifactDirectoryName,
      'artifact directory name',
    );
    final destination = Directory(targetRoot(safeChecksum, safeTarget));
    final existing = await findCompleteTarget(safeChecksum, safeTarget);
    if (existing != null) return existing;

    await destination.parent.create(recursive: true);
    if (FileSystemEntity.typeSync(stagingRoot.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FlutterBuildError(
        'SwiftPM binary artifact staging root must be a real directory',
      );
    }
    return _withPublicationLock(destination.path, () async {
      final winner = await findCompleteTarget(safeChecksum, safeTarget);
      if (winner != null) return winner;
      if (FileSystemEntity.typeSync(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await _preserveIncomplete(destination.path);
      }

      final staging = await destination.parent.createTemp(
        '.$safeTarget.staging-',
      );
      try {
        await _copyDirectoryContents(stagingRoot, staging);
        final artifactPath = p.join(staging.path, safeArtifact);
        if (FileSystemEntity.typeSync(artifactPath, followLinks: false) !=
            FileSystemEntityType.directory) {
          throw FlutterBuildError(
            'SwiftPM binary artifact root must be a real directory: '
            '$safeArtifact',
          );
        }
        if (await _containsLink(staging)) {
          throw FlutterBuildError(
            'SwiftPM binary artifact target trees must not contain links or reparse points',
            isSecurityFailure: true,
          );
        }
        final completeMetadata = <String, Object?>{
          ...metadata,
          'archiveChecksum': safeChecksum,
          'targetName': safeTarget,
          'artifactDirectoryName': safeArtifact,
          'treeDigest': await _treeDigest(Directory(artifactPath)),
        };
        await File(
          p.join(staging.path, 'metadata.json'),
        ).writeAsString(jsonEncode(completeMetadata), flush: true);
        await File(
          p.join(staging.path, '.complete'),
        ).writeAsString('', flush: true);
        if (FileSystemEntity.typeSync(destination.path, followLinks: false) !=
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
    final target = Directory(targetRoot(safeChecksum, safeTarget));
    if (FileSystemEntity.typeSync(target.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await _containsLink(target) ||
        FileSystemEntity.typeSync(
              p.join(target.path, '.complete'),
              followLinks: false,
            ) !=
            FileSystemEntityType.file) {
      return null;
    }
    try {
      final decoded = jsonDecode(
        await File(p.join(target.path, 'metadata.json')).readAsString(),
      );
      if (decoded is! Map<String, dynamic> ||
          decoded['archiveChecksum'] != safeChecksum ||
          decoded['targetName'] != safeTarget ||
          decoded['artifactDirectoryName'] is! String ||
          decoded['treeDigest'] is! String) {
        return null;
      }
      final artifactName = decoded['artifactDirectoryName'] as String;
      if (!_isSafeComponent(artifactName)) return null;
      final artifactPath = p.join(target.path, artifactName);
      if (FileSystemEntity.typeSync(artifactPath, followLinks: false) !=
              FileSystemEntityType.directory ||
          await _treeDigest(Directory(artifactPath)) != decoded['treeDigest']) {
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

  static Future<void> _copyDirectoryContents(
    Directory source,
    Directory destination,
  ) async {
    final names = <String>{};
    await for (final entity in _ioDirectory(
      source.path,
    ).list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (!_isSafeComponent(name) || !names.add(name.toLowerCase())) {
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
        await _copyDirectoryContents(entity, child);
      } else {
        throw FlutterBuildError(
          'SwiftPM binary artifact target trees must not contain symlinks',
        );
      }
    }
  }

  static Future<bool> _containsLink(Directory root) async {
    await for (final entity in _ioDirectory(
      root.path,
    ).list(recursive: true, followLinks: false)) {
      if (await _isLinkOrReparsePoint(entity.path)) return true;
    }
    return false;
  }

  static Directory _ioDirectory(String path) => Directory(_ioPath(path));

  static String _ioPath(String path) => HostPaths.long(path);

  static Future<bool> _isLinkOrReparsePoint(String path) async {
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.link) {
      return true;
    }
    if (!Platform.isWindows) return false;
    final pointer = _ioPath(path).toNativeUtf16();
    try {
      final attributes = _getFileAttributes(pointer);
      if (attributes == _invalidFileAttributes) {
        throw FileSystemException(
          'Could not read SwiftPM binary artifact attributes',
          path,
        );
      }
      return attributes & _fileAttributeReparsePoint != 0;
    } finally {
      calloc.free(pointer);
    }
  }

  static const _invalidFileAttributes = 0xffffffff;
  static const _fileAttributeReparsePoint = 0x400;
  static final int Function(Pointer<Utf16>) _getFileAttributes =
      Platform.isWindows
      ? DynamicLibrary.open('kernel32.dll').lookupFunction<
          Uint32 Function(Pointer<Utf16>),
          int Function(Pointer<Utf16>)
        >('GetFileAttributesW')
      : (_) => _invalidFileAttributes;

  static Future<String> _treeDigest(Directory root) async {
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
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      addFrame(type.toString());
      addFrame(relative);
      switch (type) {
        case FileSystemEntityType.file:
          final file = File(entity.path);
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

  static Future<void> _preserveIncomplete(String destinationPath) async {
    final parent = Directory(p.dirname(destinationPath));
    final quarantine = await parent.createTemp(
      '.${p.basename(destinationPath)}.incomplete-',
    );
    final preservedPath = p.join(quarantine.path, 'entry');
    switch (FileSystemEntity.typeSync(destinationPath, followLinks: false)) {
      case FileSystemEntityType.directory:
        await Directory(destinationPath).rename(preservedPath);
      case FileSystemEntityType.file:
        await File(destinationPath).rename(preservedPath);
      case FileSystemEntityType.link:
        await Link(destinationPath).rename(preservedPath);
      case FileSystemEntityType.notFound:
      case FileSystemEntityType.pipe:
      case FileSystemEntityType.unixDomainSock:
        throw FlutterBuildError(
          'Cannot preserve incomplete SwiftPM binary artifact destination',
        );
    }
  }

  static Future<T> _withPublicationLock<T>(
    String destinationPath,
    Future<T> Function() action,
  ) async {
    final lockKey = Platform.isWindows
        ? p.windows.normalize(p.absolute(destinationPath)).toLowerCase()
        : p.normalize(p.absolute(destinationPath));
    final previous = _localPublicationTails[lockKey];
    final done = Completer<void>();
    final tail = done.future;
    _localPublicationTails[lockKey] = tail;
    if (previous != null) await previous;

    final lockFile = File('$lockKey.lock');
    await lockFile.parent.create(recursive: true);
    final lock = await lockFile.open(mode: FileMode.append);
    try {
      await lock.lock();
      return await action();
    } finally {
      await lock.unlock();
      await lock.close();
      done.complete();
      if (identical(_localPublicationTails[lockKey], tail)) {
        final removed = _localPublicationTails.remove(lockKey);
        assert(identical(removed, tail), 'publication tail changed');
      }
    }
  }
}
