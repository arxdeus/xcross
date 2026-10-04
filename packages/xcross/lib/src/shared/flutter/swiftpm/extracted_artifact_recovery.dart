import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_artifact_preparer.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_artifact_store.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_target.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_offline_publisher.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_layout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_provenance.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmExtractedArtifactRecovery<T extends PlatformHostInterface> {
  SwiftPmExtractedArtifactRecovery({
    required this.artifactFileSystem,
    required this.binaryLayout,
    required this.binaryRecovery,
    required this.checkoutAttributes,
    required this.copyPolicy,
    required this.filesystem,
    required this.host,
    required this.publicationCoordinator,
    required this.targetPolicy,
    required this.transport,
  });
  final SwiftPmArtifactFileSystem artifactFileSystem;
  final SwiftPmBinaryLayout<T> binaryLayout;
  final SwiftPmBinaryRecovery<T> binaryRecovery;
  final SwiftPmCheckoutAttributes checkoutAttributes;
  final SwiftPmArtifactCopyPolicy copyPolicy;
  final SwiftPmFilesystem<T> filesystem;
  final T host;
  final SwiftPmPublicationCoordinator publicationCoordinator;
  final FlutterTargetBuildPolicy<T> targetPolicy;
  final SwiftPmArchiveTransport transport;
  Future<bool> stageExtractedBinaryArtifacts({
    required String scratchPath,
    required String vendorDir,
    Map<String, String> packageIdentities = const {},
    String? binaryArtifactStore,

    String? binaryArtifactFallback,
    SwiftPmBinaryAttemptState? attemptState,
    bool packageLocalArtifactJunctionCapability = false,
    PrepareSwiftPmBinaryArtifact? prepare,
    CreateSwiftPmBinaryAlias? createAlias,
    MaterializeSwiftPmBinaryArtifact? materialize,
    Future<void> Function(String destination)? removeDestination,
    Future<void> Function(String path, List<int> bytes)? writeManifest,
  }) async {
    if (binaryArtifactStore == null ||
        binaryArtifactFallback == null ||
        attemptState == null) {
      return false;
    }
    final artifactsRoot = p.join(scratchPath, 'artifacts');
    final artifacts = artifactFileSystem.directory(artifactsRoot);
    final vendor = artifactFileSystem.directory(vendorDir);
    final checkouts = artifactFileSystem.directory(
      p.join(scratchPath, 'checkouts'),
    );
    if (!artifacts.existsSync() ||
        (!vendor.existsSync() && !checkouts.existsSync())) {
      return false;
    }
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
    var changed = false;
    final remove = removeDestination ?? filesystem.deleteEntity;
    final write = writeManifest ?? filesystem.writeAtomic;
    final packageRoots = <Directory>[
      if (vendor.existsSync()) vendor,
      if (checkouts.existsSync()) checkouts,
    ];
    for (final packageRoot in packageRoots) {
      await for (final package in packageRoot.list(followLinks: false)) {
        if (package is! Directory) continue;
        final packageIdentity =
            packageIdentities[p.normalize(package.path)] ??
            p.basename(package.path).toLowerCase();

        await for (final entity in package.list(followLinks: false)) {
          if (entity is! File) continue;
          final fileName = p.basename(entity.path);
          if (fileName != 'Package.swift' &&
              !(fileName.startsWith('Package@') &&
                  fileName.endsWith('.swift'))) {
            continue;
          }
          final originalBytes = await entity.readAsBytes();
          var manifest = utf8.decode(originalBytes);
          final createdDestinations =
              <
                String,
                ({String source, SwiftPmBinaryArtifactPublication publication})
              >{};
          final provenance =
              SwiftPmBinaryProvenance.scanBinaryArtifactProvenance(
                packageIdentity: packageIdentity,
                manifestPath: entity.path,
                manifest: manifest,
              );
          for (final candidate in provenance.reversed) {
            final targetDirectory = artifactFileSystem.directory(
              p.join(artifactsRoot, packageIdentity, candidate.target.name),
            );
            if (!targetDirectory.existsSync()) continue;
            final archives = targetDirectory
                .listSync(followLinks: false)
                .whereType<File>()
                .where((file) => file.path.toLowerCase().endsWith('.zip'))
                .toList();
            final verified = <SwiftPmBinaryArtifactEntry>[];
            for (final archive in archives) {
              try {
                verified.add(
                  await preparer.prepareDownloadedArchive(
                    target: candidate.target,
                    archive: archive,
                  ),
                );
              } on FlutterBuildError catch (error) {
                if (error.isSecurityFailure) rethrow;
              }
            }
            // SwiftPM deletes the archive once it has extracted it, so the
            // usual case here is a bare extracted tree. That tree is not
            // checksum-verified and can be partial: on the Windows CI runner
            // SwiftPM hit I/O error 514 mid-resolve and left
            // FirebaseFirestoreInternal.framework without its Headers, which
            // the store then served as complete to every later build. The
            // manifest's URL and checksum rebuild the artifact from a verified
            // archive, so try that before trusting the tree.
            if (verified.isEmpty) {
              try {
                verified.add(
                  (await (prepare ?? preparer.prepare)(candidate.target)).entry,
                );
              } on FlutterBuildError catch (error) {
                if (error.isSecurityFailure) rethrow;
              }
            }
            if (verified.isEmpty) {
              final extracted = targetDirectory
                  .listSync(followLinks: false)
                  .whereType<Directory>()
                  .where(
                    (directory) =>
                        directory.path.toLowerCase().endsWith('.xcframework'),
                  )
                  .toList();
              if (extracted.length == 1) {
                final extractedStore = p.join(
                  binaryArtifactFallback,
                  'extracted-artifacts',
                );
                final store = artifactFileSystem.directory(extractedStore);
                await store.create(recursive: true);
                final staging = await store.createTemp('.extracted-');
                try {
                  final artifactName = p.basename(extracted.single.path);
                  final retainedNames = binaryLayout.libraryIdentifiers(
                    extracted.single,
                  );
                  if (retainedNames.isEmpty) continue;
                  await filesystem.copyResolvedArtifactTree(
                    extracted.single.path,
                    p.join(staging.path, artifactName),
                    includeTopLevel: (name) =>
                        name == 'Info.plist' || retainedNames.contains(name),
                  );

                  final artifactPath =
                      await SwiftPmOfflineArtifactPublisher(
                        fileSystem: artifactFileSystem,
                        publicationCoordinator: publicationCoordinator,
                      ).publish(
                        stagingRoot: staging,
                        destination: p.join(
                          extractedStore,
                          candidate.target.checksum,
                          candidate.target.name,
                        ),
                        artifactDirectoryName: artifactName,
                      );
                  verified.add(
                    SwiftPmBinaryArtifactEntry(
                      archiveChecksum: candidate.target.checksum,
                      targetName: candidate.target.name,
                      artifactPath: artifactPath,
                    ),
                  );
                } finally {
                  if (staging.existsSync()) {
                    await staging.delete(recursive: true);
                  }
                }
              }
            }
            if (verified.length != 1) continue;
            final relative = p.join(
              '.xa',
              candidate.target.checksum.toLowerCase().substring(0, 16),
              p.basename(verified.single.artifactPath),
            );

            final destination = p.join(package.path, relative);
            final fallbackDestination = destination;

            final existed =
                artifactFileSystem.typeSync(destination, followLinks: false) !=
                FileSystemEntityType.notFound;
            SwiftPmBinaryArtifactPublication? publication;
            if (existed && packageLocalArtifactJunctionCapability) {
              if (await preparer.validatesBinaryArtifactDestination(
                source: verified.single.artifactPath,
                destination: destination,
                alias: true,
              )) {
                publication = SwiftPmBinaryArtifactPublication.reused;
              }
            } else if (await preparer.validatesMaterializedBinaryArtifact(
              source: verified.single.artifactPath,
              destination: fallbackDestination,
            )) {
              publication = SwiftPmBinaryArtifactPublication.reused;
            } else {
              publication = await binaryRecovery.recoverFinalBinaryArtifact(
                provenance: candidate,
                preparedArtifactPath: verified.single.artifactPath,
                binaryArtifactStore: binaryArtifactStore,
                destination: destination,
                materializedDestination: fallbackDestination,
                attemptState: attemptState,
                packageLocalArtifactJunctionCapability:
                    packageLocalArtifactJunctionCapability,
                createAlias: createAlias,
                materialize: materialize,
              );
            }
            if (publication == null) continue;
            final usedAlias =
                packageLocalArtifactJunctionCapability &&
                await preparer.validatesBinaryArtifactDestination(
                  source: verified.single.artifactPath,
                  destination: destination,
                  alias: true,
                );
            final publishedDestination = usedAlias
                ? destination
                : fallbackDestination;
            if (publication == SwiftPmBinaryArtifactPublication.published()) {
              createdDestinations[publishedDestination] = (
                source: verified.single.artifactPath,
                publication: publication,
              );
            }
            manifest = SwiftPmBinaryTargetManifest.rewriteToLocalPaths(
              manifest,
              {candidate.target: relative},
            );

            changed = true;
          }
          if (!SwiftPmFilesystem.sameBytes(
            originalBytes,
            utf8.encode(manifest),
          )) {
            try {
              await checkoutAttributes.clear(entity.path);
              await write(entity.path, utf8.encode(manifest));
            } on Object {
              for (final created
                  in createdDestinations.entries.toList().reversed) {
                if (removeDestination != null) {
                  await remove(created.key);
                } else if (packageLocalArtifactJunctionCapability &&
                    p.isWithin(package.path, created.key)) {
                  await preparer.removeBinaryArtifactAlias(created.key);
                } else {
                  await preparer.removeMaterializedBinaryArtifact(
                    source: created.value.source,
                    destination: created.key,
                    publication: created.value.publication,
                  );
                }
              }
              rethrow;
            }
          }
        }
      }
    }
    return changed;
  }
}
