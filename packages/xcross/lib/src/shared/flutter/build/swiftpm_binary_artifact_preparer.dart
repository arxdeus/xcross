import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_artifact_store.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_target.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_archive_inspector.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_destination_publisher.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

@internal
final class SwiftPmPreparedBinaryArtifact {
  const SwiftPmPreparedBinaryArtifact({
    required this.target,
    required this.entry,
  });

  final SwiftPmRemoteBinaryTarget target;
  final SwiftPmBinaryArtifactEntry entry;
}

@internal
final class SwiftPmBinaryArtifactPreparer {
  SwiftPmBinaryArtifactPreparer({
    required SwiftPmBinaryArtifactStore store,
    required FlutterTargetBuildPolicy policy,
    required this.transport,
    required SwiftPmArtifactCopyPolicy copyPolicy,
    int maxEntries = 100000,
    int maxExpandedBytes = 4294967296,
    int maxArchiveBytes = 536870912,
  }) : _store = store,
       _maxArchiveBytes = maxArchiveBytes,
       _inspector = SwiftPmArtifactArchiveInspector(
         policy: policy,
         fileSystem: store.fileSystem,
         maxEntries: maxEntries,
         maxExpandedBytes: maxExpandedBytes,
       ),
       _publisher = SwiftPmArtifactDestinationPublisher(
         store: store,
         copyPolicy: copyPolicy,
       ) {
    if (maxEntries < 1) {
      throw ArgumentError.value(maxEntries, 'maxEntries', 'must be positive');
    }
    if (maxExpandedBytes < 0) {
      throw ArgumentError.value(
        maxExpandedBytes,
        'maxExpandedBytes',
        'must not be negative',
      );
    }
    if (maxArchiveBytes < 0) {
      throw ArgumentError.value(
        maxArchiveBytes,
        'maxArchiveBytes',
        'must not be negative',
      );
    }
  }
  final SwiftPmBinaryArtifactStore _store;
  final SwiftPmArchiveTransport transport;
  final int _maxArchiveBytes;
  final SwiftPmArtifactArchiveInspector _inspector;
  final SwiftPmArtifactDestinationPublisher _publisher;
  SwiftPmArtifactFileSystem get fileSystem => _store.fileSystem;
  Future<void> createBinaryArtifactJunction({
    required String alias,
    required String target,
  }) => _publisher.createBinaryArtifactJunction(alias: alias, target: target);
  Future<void> removeBinaryArtifactAlias(String alias) =>
      _publisher.removeBinaryArtifactAlias(alias);
  Future<SwiftPmBinaryArtifactPublication> materializeBinaryArtifact({
    required String source,
    required String destination,
    Duration timeout = const Duration(minutes: 2),
  }) => _publisher.materializeBinaryArtifact(
    source: source,
    destination: destination,
    timeout: timeout,
  );
  Future<bool> validatesBinaryArtifactDestination({
    required String source,
    required String destination,
    required bool alias,
  }) => _publisher.validatesBinaryArtifactDestination(
    source: source,
    destination: destination,
    alias: alias,
  );
  Future<bool> validatesMaterializedBinaryArtifact({
    required String source,
    required String destination,
  }) => _publisher.validatesMaterializedBinaryArtifact(
    source: source,
    destination: destination,
  );
  Future<void> removeMaterializedBinaryArtifact({
    required String source,
    required String destination,
    required SwiftPmBinaryArtifactPublication publication,
  }) => _publisher.removeMaterializedBinaryArtifact(
    source: source,
    destination: destination,
    publication: publication,
  );
  Future<SwiftPmPreparedBinaryArtifact> prepare(
    SwiftPmRemoteBinaryTarget target,
  ) async {
    final existing = await _store.findCompleteTarget(
      target.checksum,
      target.name,
    );
    if (existing != null) {
      return SwiftPmPreparedBinaryArtifact(target: target, entry: existing);
    }

    File archive;
    final cached = fileSystem.file(_store.archivePath(target.checksum));
    if (cached.existsSync()) {
      archive = await _store.publishArchive(
        cached,
        target.checksum,
        maximumBytes: _maxArchiveBytes,
      );
    } else {
      final stagingParent = fileSystem.directory(
        p.join(_store.root, '.staging'),
      );
      await stagingParent.create(recursive: true);
      final staging = await stagingParent.createTemp('download-');
      final downloaded = fileSystem.file(p.join(staging.path, 'archive.zip'));
      try {
        try {
          await transport.download(target.url, downloaded, _maxArchiveBytes);
        } on FlutterBuildError {
          rethrow;
        } on Object {
          throw FlutterBuildError(
            'Failed to download SwiftPM binary artifact from '
            '${_redactedUrl(target.url)}',
          );
        }
        archive = await _store.publishArchive(
          downloaded,
          target.checksum,
          maximumBytes: _maxArchiveBytes,
        );
      } finally {
        if (staging.existsSync()) await staging.delete(recursive: true);
      }
    }

    final entry = await prepareDownloadedArchive(
      target: target,
      archive: archive,
    );
    return SwiftPmPreparedBinaryArtifact(target: target, entry: entry);
  }

  Future<SwiftPmBinaryArtifactEntry> prepareDownloadedArchive({
    required SwiftPmRemoteBinaryTarget target,
    required File archive,
  }) async {
    final existing = await _store.findCompleteTarget(
      target.checksum,
      target.name,
    );
    if (existing != null) return existing;

    await _store.publishArchive(
      archive,
      target.checksum,
      maximumBytes: _maxArchiveBytes,
    );
    final bytes = Uint8List.fromList(
      await _store.readVerifiedArchiveBytes(
        target.checksum,
        maximumBytes: _maxArchiveBytes,
      ),
    );
    final decoded = _inspector.decode(bytes);
    final inspected = _inspector.inspect(decoded, target);
    final stagingParent = fileSystem.directory(p.join(_store.root, '.staging'));
    await stagingParent.create(recursive: true);
    final staging = await stagingParent.createTemp('extract-');
    try {
      final artifact = fileSystem.directory(
        p.join(staging.path, inspected.artifactDirectoryName),
      );
      await artifact.create(recursive: true);
      try {
        await _inspector.extractSelected(inspected, artifact);
      } on FlutterBuildError {
        rethrow;
      } on Object {
        throw FlutterBuildError(
          'SwiftPM binary artifact selected content could not be decompressed',
        );
      }
      _inspector.validateDeclaredPaths(inspected.library, artifact);
      return await _store.publishTarget(
        checksum: target.checksum,
        targetName: target.name,
        stagingRoot: staging,
        artifactDirectoryName: inspected.artifactDirectoryName,
        metadata: {
          'formatVersion': 1,
          'libraryIdentifier': inspected.library.identifier,
        },
      );
    } finally {
      if (staging.existsSync()) await staging.delete(recursive: true);
    }
  }

  static String _redactedUrl(Uri url) {
    final last = url.pathSegments
        .where((segment) => segment.isNotEmpty)
        .lastOrNull;
    final path = last == null ? '' : '/$last';
    return Uri(
      scheme: url.scheme,
      host: url.host,
      port: url.hasPort ? url.port : null,
      path: path,
    ).toString();
  }
}
