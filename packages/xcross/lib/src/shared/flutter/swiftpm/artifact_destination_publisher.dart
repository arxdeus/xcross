import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_artifact_store.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_offline_publisher.dart';

@internal
final class SwiftPmBinaryArtifactPublication {
  SwiftPmBinaryArtifactPublication._(this.nonce);

  static final reused = SwiftPmBinaryArtifactPublication._(null);
  factory SwiftPmBinaryArtifactPublication.published() =>
      SwiftPmBinaryArtifactPublication._(
        '${pid}_${DateTime.now().microsecondsSinceEpoch}',
      );

  final String? nonce;

  @override
  bool operator ==(Object other) =>
      other is SwiftPmBinaryArtifactPublication &&
      ((nonce == null && other.nonce == null) ||
          (nonce != null && other.nonce != null));

  @override
  int get hashCode => nonce == null ? 0 : 1;
}

@internal
final class SwiftPmArtifactDestinationPublisher {
  const SwiftPmArtifactDestinationPublisher({
    required SwiftPmBinaryArtifactStore store,
    required this.copyPolicy,
  }) : _store = store;
  final SwiftPmBinaryArtifactStore _store;
  final SwiftPmArtifactCopyPolicy copyPolicy;
  SwiftPmArtifactFileSystem get fileSystem => _store.fileSystem;
  Future<void> createBinaryArtifactJunction({
    required String alias,
    required String target,
  }) => _withDestinationLock(alias, () async {
    if (!await _publishedSource(target)) {
      throw FileSystemException(
        'SwiftPM binary artifact target is not a complete store entry',
        target,
      );
    }
    await _removeBinaryArtifactAlias(alias);
    final absoluteAlias = p.normalize(p.absolute(alias));
    final resolvedTarget = p.normalize(
      p.absolute(await fileSystem.directory(target).resolveSymbolicLinks()),
    );
    final nonce = '${pid}_${DateTime.now().microsecondsSinceEpoch}';
    final temporaryAlias = '$absoluteAlias.xcross-junction-$nonce';
    var published = false;
    try {
      await _createAlias(temporaryAlias, resolvedTarget);
      if (!await _isAliasTo(temporaryAlias, resolvedTarget)) {
        throw FileSystemException(
          'SwiftPM binary artifact junction has an unexpected type or target',
          temporaryAlias,
        );
      }
      await fileSystem.directory(temporaryAlias).rename(absoluteAlias);
      published = true;
      if (!await _isAliasTo(absoluteAlias, resolvedTarget)) {
        throw FileSystemException(
          'Published SwiftPM binary artifact alias has an unexpected type or target',
          absoluteAlias,
        );
      }
      await _writeAliasMarker(absoluteAlias, resolvedTarget, nonce);
    } catch (_) {
      final cleanup = published ? absoluteAlias : temporaryAlias;
      if (await _isAliasTo(cleanup, resolvedTarget)) {
        await _deleteVerifiedAlias(cleanup);
      }
      rethrow;
    }
  });

  Future<void> removeBinaryArtifactAlias(String alias) =>
      _withDestinationLock(alias, () => _removeBinaryArtifactAlias(alias));

  Future<void> _removeBinaryArtifactAlias(String alias) async {
    final absoluteAlias = p.normalize(p.absolute(alias));
    final marker = fileSystem.file(_aliasMarkerPath(absoluteAlias));
    final type = fileSystem.typeSync(absoluteAlias, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      if (marker.existsSync()) await marker.delete();
      return;
    }
    final ownership = await _managedAliasTarget(absoluteAlias, marker);
    if (ownership == null ||
        !await _isAliasTo(absoluteAlias, ownership.target)) {
      throw FileSystemException(
        'Refusing to remove an unowned or changed SwiftPM binary artifact path',
        absoluteAlias,
      );
    }
    final revalidated = await _managedAliasTarget(absoluteAlias, marker);
    if (revalidated != ownership ||
        !await _isAliasTo(absoluteAlias, ownership.target)) {
      throw FileSystemException(
        'Refusing to remove a changed SwiftPM binary artifact alias',
        absoluteAlias,
      );
    }
    await _deleteVerifiedAlias(absoluteAlias);
    final markerAfterDelete = await _managedAliasTarget(absoluteAlias, marker);
    if (markerAfterDelete != null &&
        markerAfterDelete.target == ownership.target &&
        markerAfterDelete.nonce == ownership.nonce) {
      await marker.delete();
    }
  }

  Future<void> _createAlias(String alias, String target) =>
      _store.fileSystem.createAlias(alias, target);
  Future<bool> _isAliasTo(String alias, String target) =>
      _store.fileSystem.isAliasTo(alias, target);
  Future<void> _deleteVerifiedAlias(String alias) =>
      _store.fileSystem.deleteAlias(alias);

  Future<void> _writeAliasMarker(
    String alias,
    String target,
    String nonce,
  ) async {
    final marker = fileSystem.file(_aliasMarkerPath(alias));
    final temporary = fileSystem.file('${marker.path}.tmp-$nonce');
    try {
      await temporary.writeAsString(
        jsonEncode({'alias': alias, 'target': target, 'nonce': nonce}),
        flush: true,
      );
      await temporary.rename(marker.path);
    } catch (_) {
      if (temporary.existsSync()) await temporary.delete();
      rethrow;
    }
  }

  String _aliasMarkerPath(String alias) => '$alias.xcross-alias.json';

  Future<({String target, String nonce})?> _managedAliasTarget(
    String alias,
    File marker,
  ) async {
    if (!marker.existsSync()) return null;
    try {
      final value = jsonDecode(await marker.readAsString());
      if (value is! Map<String, dynamic> ||
          value['alias'] is! String ||
          value['target'] is! String ||
          value['nonce'] is! String ||
          _pathKey(p.normalize(p.absolute(value['alias'] as String))) !=
              _pathKey(alias)) {
        return null;
      }
      return (
        target: p.normalize(p.absolute(value['target'] as String)),
        nonce: value['nonce'] as String,
      );
    } on Object {
      return null;
    }
  }

  Future<SwiftPmBinaryArtifactPublication> materializeBinaryArtifact({
    required String source,
    required String destination,
    Duration timeout = const Duration(minutes: 2),
  }) => _withDestinationLock(destination, () async {
    await _validateMaterializationSource(source);
    final existing = await _existingMaterialization(source, destination);
    if (existing != null) return existing;
    final parent = fileSystem.directory(p.dirname(destination));
    await parent.create(recursive: true);
    final temporary = await parent.createTemp('.x-');
    var cleanupTemporary = true;
    try {
      try {
        await copyPolicy.copy(
          source: source,
          destination: temporary,
          timeout: timeout,
        );
      } on SwiftPmLiveCopyException {
        cleanupTemporary = false;
        rethrow;
      }
      if (!await _sameArtifactTree(source, temporary.path)) {
        throw FileSystemException(
          'SwiftPM binary artifact copy completed with incomplete content',
          temporary.path,
        );
      }
      return await _publishMaterialization(
        source: source,
        destination: destination,
        temporary: temporary,
      );
    } finally {
      if (cleanupTemporary && temporary.existsSync()) {
        await temporary.delete(recursive: true);
      }
    }
  });

  Future<void> _validateMaterializationSource(String source) async {
    if (await _publishedSource(source)) return;
    throw FileSystemException(
      'SwiftPM binary artifact source is not a complete store entry',
      source,
    );
  }

  Future<SwiftPmBinaryArtifactPublication?> _existingMaterialization(
    String source,
    String destination,
  ) async {
    if (fileSystem.typeSync(destination, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return null;
    }
    if (await validatesMaterializedBinaryArtifact(
      source: source,
      destination: destination,
    )) {
      return SwiftPmBinaryArtifactPublication.reused;
    }
    throw FileSystemException(
      'SwiftPM binary artifact destination already exists but is not the expected artifact',
      destination,
    );
  }

  Future<SwiftPmBinaryArtifactPublication> _publishMaterialization({
    required String source,
    required String destination,
    required Directory temporary,
  }) async {
    try {
      final publication = SwiftPmBinaryArtifactPublication.published();
      await temporary.rename(destination);
      await _writeMaterializationMarker(
        destination,
        source,
        publication.nonce!,
      );
      return publication;
    } on FileSystemException {
      if (!await validatesMaterializedBinaryArtifact(
        source: source,
        destination: destination,
      )) {
        rethrow;
      }
      return SwiftPmBinaryArtifactPublication.reused;
    }
  }

  Future<bool> validatesBinaryArtifactDestination({
    required String source,
    required String destination,
    required bool alias,
  }) async {
    if (!await _publishedSource(source)) return false;
    if (!alias) return _sameArtifactTree(source, destination);
    final absoluteDestination = p.normalize(p.absolute(destination));
    final marker = fileSystem.file(_aliasMarkerPath(absoluteDestination));
    final ownership = await _managedAliasTarget(absoluteDestination, marker);
    return ownership != null &&
        _pathKey(ownership.target) ==
            _pathKey(p.normalize(p.absolute(source))) &&
        await _isAliasTo(absoluteDestination, ownership.target);
  }

  Future<bool> validatesMaterializedBinaryArtifact({
    required String source,
    required String destination,
  }) => validatesBinaryArtifactDestination(
    source: source,
    destination: destination,
    alias: false,
  );

  Future<void> removeMaterializedBinaryArtifact({
    required String source,
    required String destination,
    required SwiftPmBinaryArtifactPublication publication,
  }) => _withDestinationLock(destination, () async {
    final nonce = publication.nonce;
    if (nonce == null) return;
    final marker = fileSystem.file('$destination.xcross-materialization.json');
    final ownership = await _materializationOwnership(marker);
    if (ownership == null ||
        ownership.nonce != nonce ||
        _pathKey(ownership.destination) !=
            _pathKey(p.normalize(p.absolute(destination))) ||
        _pathKey(ownership.source) !=
            _pathKey(p.normalize(p.absolute(source))) ||
        !await _sameArtifactTree(source, destination)) {
      return;
    }
    final revalidated = await _materializationOwnership(marker);
    if (revalidated == null ||
        revalidated.nonce != nonce ||
        !await _sameArtifactTree(source, destination)) {
      return;
    }
    await fileSystem.directory(destination).delete(recursive: true);
    if (marker.existsSync()) await marker.delete();
  });

  Future<void> _writeMaterializationMarker(
    String destination,
    String source,
    String nonce,
  ) async {
    final marker = fileSystem.file('$destination.xcross-materialization.json');
    await marker.writeAsString(
      jsonEncode({
        'destination': p.normalize(p.absolute(destination)),
        'source': p.normalize(p.absolute(source)),
        'nonce': nonce,
      }),
      flush: true,
    );
  }

  Future<({String destination, String source, String nonce})?>
  _materializationOwnership(File marker) async {
    try {
      final value = jsonDecode(await marker.readAsString());
      if (value is! Map<String, dynamic> ||
          value['destination'] is! String ||
          value['source'] is! String ||
          value['nonce'] is! String) {
        return null;
      }
      return (
        destination: p.normalize(p.absolute(value['destination'] as String)),
        source: p.normalize(p.absolute(value['source'] as String)),
        nonce: value['nonce'] as String,
      );
    } on Object {
      return null;
    }
  }

  Future<bool> _sameArtifactTree(String source, String destination) async {
    if (fileSystem.typeSync(source, followLinks: false) !=
            FileSystemEntityType.directory ||
        fileSystem.typeSync(destination, followLinks: false) !=
            FileSystemEntityType.directory) {
      return false;
    }
    final sourceRoot = fileSystem.directory(source);
    final destinationRoot = fileSystem.directory(destination);
    final sourcePath = sourceRoot.path;
    final destinationPath = destinationRoot.path;
    final sourceEntities = sourceRoot.listSync(
      recursive: true,
      followLinks: false,
    );
    final destinationEntities = destinationRoot.listSync(
      recursive: true,
      followLinks: false,
    );
    if (sourceEntities.length != destinationEntities.length) return false;
    final destinationByPath = {
      for (final entity in destinationEntities)
        _pathKey(p.relative(entity.path, from: destinationPath)): entity,
    };
    for (final entity in sourceEntities) {
      final relative = _pathKey(p.relative(entity.path, from: sourcePath));

      final other = destinationByPath[relative];
      final type = fileSystem.typeSync(entity.path, followLinks: false);
      if (other == null ||
          type != fileSystem.typeSync(other.path, followLinks: false)) {
        return false;
      }
      if (type == FileSystemEntityType.file &&
          !_sameBytes(
            await fileSystem.file(entity.path).readAsBytes(),
            await fileSystem.file(other.path).readAsBytes(),
          )) {
        return false;
      }
    }
    return true;
  }

  static bool _sameBytes(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  Future<bool> _publishedSource(String source) async =>
      await _completeEntryContaining(source) ||
      await SwiftPmOfflineArtifactPublisher(
        fileSystem: fileSystem,
        publicationCoordinator: _store.publicationCoordinator,
      ).isPublishedArtifact(source);

  Future<bool> _completeEntryContaining(String target) async {
    final root = p.normalize(p.absolute(fileSystem.processPath(_store.root)));
    final absoluteTarget = p.normalize(
      p.absolute(fileSystem.processPath(target)),
    );
    if (!p.isWithin(root, absoluteTarget)) return false;
    var current = absoluteTarget;
    while (p.isWithin(root, current)) {
      final metadata = fileSystem.file(p.join(current, 'metadata.json'));
      if (fileSystem.file(p.join(current, '.complete')).existsSync() &&
          metadata.existsSync()) {
        try {
          final decoded = jsonDecode(await metadata.readAsString());
          if (decoded is Map<String, dynamic> &&
              decoded['archiveChecksum'] is String &&
              decoded['targetName'] is String) {
            final entry = await _store.findCompleteTarget(
              decoded['archiveChecksum'] as String,
              decoded['targetName'] as String,
            );
            return entry != null &&
                _pathKey(
                      p.normalize(
                        p.absolute(fileSystem.processPath(entry.artifactPath)),
                      ),
                    ) ==
                    _pathKey(absoluteTarget);
          }
        } on FormatException {
          return false;
        } on FileSystemException {
          return false;
        }
      }
      current = p.dirname(current);
    }
    return false;
  }

  String _pathKey(String path) => _store.host.paths.pathKey(path);

  Future<T> _withDestinationLock<T>(
    String destination,
    Future<T> Function() action,
  ) => _store.publicationCoordinator.run(destination, action);
}
