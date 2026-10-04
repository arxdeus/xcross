import 'dart:async';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_artifact_preparer.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_artifact_store.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_destination_publisher.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_layout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_provenance.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

@internal
const String flutterFrameworkPackageName = 'FlutterFramework';
@internal
const String pluginsProductName = 'FlutterPluginsGenerated';

@internal
final class SwiftPmBinaryRecovery<T extends PlatformHostInterface> {
  SwiftPmBinaryRecovery({
    required this.artifactFileSystem,
    required this.binaryLayout,
    required this.binaryProvenance,
    required this.copyPolicy,
    required this.filesystem,
    required this.host,
    required this.publicationCoordinator,
    required this.targetPolicy,
    required this.transport,
  });
  final SwiftPmArtifactFileSystem artifactFileSystem;
  final SwiftPmBinaryLayout<T> binaryLayout;
  final SwiftPmBinaryProvenance<T> binaryProvenance;
  final SwiftPmArtifactCopyPolicy copyPolicy;
  final SwiftPmFilesystem<T> filesystem;
  final T host;
  final SwiftPmPublicationCoordinator publicationCoordinator;
  final FlutterTargetBuildPolicy<T> targetPolicy;
  final SwiftPmArchiveTransport transport;
  Future<void> resolveWithFinalBinaryRecovery({
    required Future<void> Function() resolve,
    required Future<bool> Function() recover,
  }) async {
    try {
      await resolve();
    } on Object catch (error) {
      // A resolve we killed for exceeding its own timeout is not a missing
      // binary artifact, and re-running it just waits out the same stall
      // again. Two such rounds are what kept the Windows job alive to the
      // 90-minute job limit even after the timeout started firing.
      if (SwiftPmBinaryRecovery.isResolveTimeout(error)) rethrow;
      if (!await recover()) rethrow;
      await resolve();
    }
  }

  /// Whether [error] is a resolve this tool killed for exceeding its timeout.
  ///
  /// Distinguishes our own deliberate kill from a failure of the work, so
  /// recovery and retry paths can decline to run the same stall again.
  static bool isResolveTimeout(Object error) =>
      error.toString().contains('and was killed') ||
      error.toString().contains('took longer than');

  Future<SwiftPmBinaryArtifactPublication?> recoverFinalBinaryArtifact({
    required SwiftPmBinaryArtifactProvenance provenance,
    required String preparedArtifactPath,
    required String binaryArtifactStore,
    required String destination,
    required SwiftPmBinaryAttemptState attemptState,
    required bool packageLocalArtifactJunctionCapability,

    String? materializedDestination,
    CreateSwiftPmBinaryAlias? createAlias,
    MaterializeSwiftPmBinaryArtifact? materialize,
  }) async {
    final key = binaryProvenance.binaryArtifactAttemptKey(provenance);
    if (attemptState.finalRecovered.contains(key)) return null;
    attemptState.finalRecovered.add(key);
    final preparer = SwiftPmBinaryArtifactPreparer(
      policy: targetPolicy,
      transport: transport,
      copyPolicy: copyPolicy,
      store: SwiftPmBinaryArtifactStore(
        binaryArtifactStore,
        host: host,
        publicationCoordinator: publicationCoordinator,
        fileSystem: artifactFileSystem,
      ),
    );
    final create = createAlias ?? preparer.createBinaryArtifactJunction;
    final copy = materialize ?? preparer.materializeBinaryArtifact;
    if (packageLocalArtifactJunctionCapability) {
      try {
        final started = Stopwatch()..start();
        await create(alias: destination, target: preparedArtifactPath);
        filesystem.traceBinaryOperation(
          target: provenance.target.name,
          operation: 'recover',
          extractedBytes: filesystem.directoryBytes(preparedArtifactPath),
          elapsedMilliseconds: started.elapsedMilliseconds,
          attempt: 1,
        );
        return SwiftPmBinaryArtifactPublication.published();
      } on Object {
        if (attemptState.copied.contains(key)) return null;
      }
    }
    if (attemptState.copied.contains(key)) return null;
    attemptState.copied.add(key);
    final started = Stopwatch()..start();
    final publication = await copy(
      source: preparedArtifactPath,
      destination: materializedDestination ?? destination,
    );
    filesystem.traceBinaryOperation(
      target: provenance.target.name,
      operation: 'copy',
      extractedBytes: filesystem.directoryBytes(preparedArtifactPath),
      elapsedMilliseconds: started.elapsedMilliseconds,
      attempt: 1,
    );
    return publication;
  }

  Future<bool> recoverBootstrapBinaryArtifacts({
    required String scratchPath,
    required String binaryArtifactStore,
    required Iterable<SwiftPmBinaryArtifactProvenance> provenance,
    required SwiftPmBinaryAttemptState attemptState,

    bool swiftPmArtifactJunctionCapability = false,
  }) async {
    final artifactsRoot = p.join(scratchPath, 'artifacts');
    final artifacts = artifactFileSystem.directory(artifactsRoot);
    if (!artifacts.existsSync()) return false;
    final preparer = SwiftPmBinaryArtifactPreparer(
      policy: targetPolicy,
      transport: transport,
      copyPolicy: copyPolicy,
      store: SwiftPmBinaryArtifactStore(
        binaryArtifactStore,
        host: host,
        publicationCoordinator: publicationCoordinator,
        fileSystem: artifactFileSystem,
      ),
    );
    final candidates =
        <
          String,
          List<
            ({Directory directory, SwiftPmBinaryArtifactProvenance provenance})
          >
        >{};
    for (final package in artifacts.listSync(followLinks: false)) {
      if (package is! Directory ||
          binaryProvenance.swiftPmComponent(p.basename(package.path)) ==
              'extract') {
        continue;
      }
      for (final targetDirectory in package.listSync(followLinks: false)) {
        if (targetDirectory is! Directory) continue;
        final match = binaryProvenance.matchBinaryArtifactProvenance(
          artifactPath: artifactFileSystem.processPath(targetDirectory.path),
          artifactsRoot: artifactsRoot,
          provenance: provenance,
        );
        if (match == null) continue;
        final key = binaryProvenance.binaryArtifactAttemptKey(match);
        (candidates[key] ??= []).add((
          directory: targetDirectory,
          provenance: match,
        ));
      }
    }

    var recovered = false;
    for (final candidateList in candidates.values) {
      if (candidateList.length != 1) continue;
      final candidate = candidateList.single;
      final key = binaryProvenance.binaryArtifactAttemptKey(
        candidate.provenance,
      );
      if (attemptState.bootstrapRecovered.contains(key)) continue;
      final completeArtifacts = candidate.directory
          .listSync(followLinks: false)
          .whereType<Directory>()
          .where(
            (directory) =>
                directory.path.toLowerCase().endsWith('.xcframework'),
          );
      var hasFinalArtifact = false;
      for (final artifact in completeArtifacts) {
        if (await binaryLayout.hasCompleteSwiftPmArtifact(artifact)) {
          hasFinalArtifact = true;
          break;
        }
      }
      if (hasFinalArtifact) continue;
      final archives = candidate.directory
          .listSync(followLinks: false)
          .whereType<File>()
          .where((file) => file.path.toLowerCase().endsWith('.zip'));
      final verified = <SwiftPmPreparedBinaryArtifact>[];
      for (final archive in archives) {
        try {
          verified.add(
            SwiftPmPreparedBinaryArtifact(
              target: candidate.provenance.target,
              entry: await preparer.prepareDownloadedArchive(
                target: candidate.provenance.target,
                archive: archive,
              ),
            ),
          );
        } on FlutterBuildError catch (error) {
          if (error.isSecurityFailure) rethrow;
          continue;
        } on Object {
          continue;
        }
      }
      if (verified.length != 1) continue;
      final prepared = verified.single;
      final destination = p.join(
        candidate.directory.path,
        p.basename(prepared.entry.artifactPath),
      );
      if (swiftPmArtifactJunctionCapability) {
        try {
          await preparer.createBinaryArtifactJunction(
            alias: destination,
            target: prepared.entry.artifactPath,
          );
        } on FileSystemException {
          if (attemptState.copied.contains(key)) continue;
          attemptState.copied.add(key);
          await preparer.materializeBinaryArtifact(
            source: prepared.entry.artifactPath,
            destination: destination,
          );
        }
      } else {
        if (attemptState.copied.contains(key)) continue;
        attemptState.copied.add(key);
        await preparer.materializeBinaryArtifact(
          source: prepared.entry.artifactPath,
          destination: destination,
        );
      }
      attemptState.bootstrapRecovered.add(key);
      recovered = true;
    }
    return recovered;
  }
}
