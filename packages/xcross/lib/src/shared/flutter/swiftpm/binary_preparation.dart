import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_artifact_preparer.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_artifact_store.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_target.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_destination_publisher.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

@internal
const String flutterFrameworkPackageName = 'FlutterFramework';
@internal
const String pluginsProductName = 'FlutterPluginsGenerated';

@internal
final class SwiftPmBinaryPreparation<T extends PlatformHostInterface> {
  SwiftPmBinaryPreparation({
    required this.artifactFileSystem,
    required this.copyPolicy,
    required this.filesystem,
    required this.host,
    required this.publicationCoordinator,
    required this.targetPolicy,
    required this.transport,
  });
  final SwiftPmArtifactFileSystem artifactFileSystem;
  final SwiftPmArtifactCopyPolicy copyPolicy;
  final SwiftPmFilesystem<T> filesystem;
  final T host;
  final SwiftPmPublicationCoordinator publicationCoordinator;
  final FlutterTargetBuildPolicy<T> targetPolicy;
  final SwiftPmArchiveTransport transport;
  Future<void> prepareSupportedBinaryArtifacts({
    required String packageRoot,
    required String binaryArtifactStore,
    required String binaryArtifactFallback,
    required bool packageLocalArtifactJunctionCapability,

    PrepareSwiftPmBinaryArtifact? prepare,
    CreateSwiftPmBinaryAlias? createAlias,
    MaterializeSwiftPmBinaryArtifact? materialize,
    Future<void> Function(String alias)? removeAlias,
    Future<void> Function(String path, List<int> bytes)? writeManifest,
  }) async {
    final root = artifactFileSystem.directory(filesystem.ioPath(packageRoot));
    if (!root.existsSync()) return;

    final store = SwiftPmBinaryArtifactStore(
      binaryArtifactStore,
      host: host,
      publicationCoordinator: publicationCoordinator,
      fileSystem: artifactFileSystem,
    );
    final preparer = SwiftPmBinaryArtifactPreparer(
      policy: targetPolicy,
      transport: transport,
      copyPolicy: copyPolicy,
      store: store,
    );
    final runPrepare = prepare ?? preparer.prepare;
    final create = createAlias ?? preparer.createBinaryArtifactJunction;
    final copy = materialize ?? preparer.materializeBinaryArtifact;
    final remove = removeAlias ?? preparer.removeBinaryArtifactAlias;
    final write = writeManifest ?? filesystem.writeAtomic;
    final manifests = root
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) {
          final name = p.basename(file.path);
          return name == 'Package.swift' ||
              (name.startsWith('Package@') && name.endsWith('.swift'));
        });
    for (final manifestFile in manifests) {
      final manifestPath = artifactFileSystem.processPath(manifestFile.path);
      final original = await manifestFile.readAsString();
      final targets = SwiftPmBinaryTargetManifest.discover(original);
      if (targets.isEmpty) continue;
      final createdDestinations =
          <
            String,
            ({String source, SwiftPmBinaryArtifactPublication? publication})
          >{};
      final localPaths = <SwiftPmRemoteBinaryTarget, String>{};
      try {
        for (final target in targets) {
          String? createdDestination;
          try {
            final started = Stopwatch()..start();
            final reused = await store.findCompleteTarget(
              target.checksum,
              target.name,
            );
            final hadArchive = artifactFileSystem
                .file(store.archivePath(target.checksum))
                .existsSync();
            final result = await runPrepare(target);
            filesystem.traceBinaryOperation(
              target: target.name,
              operation: reused != null
                  ? 'reuse'
                  : hadArchive
                  ? 'extract'
                  : 'download',
              archiveBytes: filesystem.fileBytes(
                store.archivePath(target.checksum),
              ),
              extractedBytes: filesystem.directoryBytes(
                result.entry.artifactPath,
              ),
              elapsedMilliseconds: started.elapsedMilliseconds,
              attempt: 0,
            );
            final artifact = result.entry.artifactPath;
            final relative = p.join(
              '.xa',
              target.checksum.toLowerCase().substring(0, 16),
              p.basename(artifact),
            );

            var aliased = false;
            if (packageLocalArtifactJunctionCapability) {
              final alias = p.join(p.dirname(manifestPath), relative);

              await artifactFileSystem
                  .directory(p.dirname(alias))
                  .create(recursive: true);
              try {
                final existed =
                    artifactFileSystem.typeSync(alias, followLinks: false) !=
                    FileSystemEntityType.notFound;
                if (existed) {
                  if (!await preparer.validatesBinaryArtifactDestination(
                    source: artifact,
                    destination: alias,
                    alias: true,
                  )) {
                    throw FileSystemException(
                      'SwiftPM binary artifact alias already exists but is not managed for the expected artifact',
                      alias,
                    );
                  }
                } else {
                  await create(alias: alias, target: artifact);
                  createdDestination = alias;
                  createdDestinations[alias] = (
                    source: artifact,
                    publication: null,
                  );
                }
                localPaths[target] = relative;
                aliased = true;
              } on Object {
                if (createdDestination == alias) {
                  await remove(alias);
                  createdDestinations.remove(alias);
                  createdDestination = null;
                }
              }
            }
            if (!aliased) {
              final destination = p.join(p.dirname(manifestPath), relative);
              final publication = await copy(
                source: artifact,
                destination: destination,
              );

              if (publication == SwiftPmBinaryArtifactPublication.published()) {
                createdDestination = destination;
                createdDestinations[destination] = (
                  source: artifact,
                  publication: publication,
                );
              }
              localPaths[target] = relative;
            }
          } on FlutterBuildError catch (error) {
            if (error.isSecurityFailure) rethrow;
            localPaths.remove(target);
            if (createdDestination != null) {
              final created = createdDestinations.remove(createdDestination)!;
              if (created.publication == null) {
                await remove(createdDestination);
              } else {
                await preparer.removeMaterializedBinaryArtifact(
                  source: created.source,
                  destination: createdDestination,
                  publication: created.publication!,
                );
              }
            }
          }
        }
        if (localPaths.isNotEmpty) {
          final rewritten = SwiftPmBinaryTargetManifest.rewriteToLocalPaths(
            original,
            localPaths,
          );
          if (rewritten != original) {
            await write(manifestPath, utf8.encode(rewritten));
          }
          // SwiftPM invalidates on timestamps, and a manifest's timestamp
          // invalidates every target in its package. Vendoring restores the
          // upstream manifest with `git reset --hard` before each build, so
          // this rewrite lands on a file git has just re-stamped: 12
          // manifests per run, each with the same bytes as the run before,
          // and that alone made the whole Firebase graph recompile on every
          // incremental build.
          //
          // Neither the pre-write timestamp nor "skip when unchanged" can
          // fix that, because the reset moves the timestamp and reverts the
          // content before this code runs. Deriving the timestamp from the
          // bytes does: identical patched manifests always carry an
          // identical timestamp, and a genuinely new patch still gets a new
          // one.
          await filesystem.stampByContent(manifestPath, rewritten);
        }
      } on Object {
        for (final created in createdDestinations.entries.toList().reversed) {
          if (created.value.publication == null) {
            await remove(created.key);
          } else {
            await preparer.removeMaterializedBinaryArtifact(
              source: created.value.source,
              destination: created.key,
              publication: created.value.publication!,
            );
          }
        }
        rethrow;
      }
    }
  }
}
