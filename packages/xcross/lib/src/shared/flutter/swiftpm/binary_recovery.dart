import 'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_identity.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/flutter/build/internal/host_symlink_capability.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_capabilities.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/assembly.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_driver.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_plan.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_links.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_vendor.dart';
import 'package:xcross/src/shared/flutter/swiftpm/discovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_source_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/interop_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest.dart';
import 'package:xcross/src/shared/flutter/swiftpm/module_files.dart';
import 'package:xcross/src/shared/flutter/swiftpm/package_metadata.dart';
import 'package:xcross/src/shared/flutter/swiftpm/plugin_overlay.dart';
import 'package:xcross/src/shared/flutter/swiftpm/preview_macro_compiler.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_fallback.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_repair.dart';
import 'package:xcross/src/shared/flutter/swiftpm/toolchain.dart';
import 'package:xcross/src/shared/flutter/swiftpm/workspace_stager.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/build/swiftpm_binary_artifact_preparer.dart';
import 'package:xcross/src/flutter/build/swiftpm_binary_artifact_store.dart';
import 'package:xcross/src/flutter/build/swiftpm_binary_target.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_offline_publisher.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_dependencies.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_repair.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmBinaryRecovery<T extends PlatformHostInterface> {
  SwiftPmBinaryRecovery({required this.artifactFileSystem,required this.checkoutAttributes,required this.copyPolicy,required this.dependencyPreparation,required this.filesystem,required this.host,required this.hostPolicy,required this.interopRepair,required this.publicationCoordinator,required this.runner,required this.sourceRepair,required this.targetPolicy,required this.transport});
  final SwiftPmArtifactFileSystem artifactFileSystem;
  final SwiftPmCheckoutAttributes checkoutAttributes;
  final SwiftPmArtifactCopyPolicy copyPolicy;
  final SwiftPmDependencyPreparation<T> dependencyPreparation;
  final SwiftPmFilesystem<T> filesystem;
  final T host;
  final SwiftPmHostPolicy hostPolicy;
  final SwiftPmInteropRepair<T> interopRepair;
  final SwiftPmPublicationCoordinator publicationCoordinator;
  final ProcessRunner<T> runner;
  final SwiftPmSourceRepair<T> sourceRepair;
  final FlutterTargetBuildPolicy<T> targetPolicy;
  final SwiftPmArchiveTransport transport;

  static bool isTransientNetworkFailure(Object error) {
    final text = error.toString().toLowerCase();
    // Our own timeout already waited the full budget; retrying it would
    // multiply the very stall the timeout exists to cut short.
    if (text.contains('and was killed')) return false;
    return SwiftPmSourceRepair.transientNetworkFailureMarkers.any(
      text.contains,
    );
  }

  /// Runs [action], retrying while it fails for an apparently transient
  /// network reason.
  ///
  /// Anything else propagates on the first attempt, so a genuine build error
  /// still fails fast instead of being retried three times.
  Future<void> retryingTransientNetworkFailure(
    Future<void> Function() action, {
    required String label,
    int attempts = 3,
    Duration backoff = const Duration(seconds: 5),
    Future<void> Function(Duration)? delay,
  }) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await action();
      } on Object catch (error) {
        if (attempt >= attempts ||
            !SwiftPmBinaryRecovery.isTransientNetworkFailure(error)) {
          rethrow;
        }
        final pause = backoff * attempt;
        runner.log.logTrace(
          '$label failed on a transient network error '
          '(attempt $attempt of $attempts), retrying in '
          '${pause.inSeconds}s: $error',
        );
        await (delay ?? Future<void>.delayed)(pause);
      }
    }
  }

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
    final root = Directory(filesystem.ioPath(packageRoot));
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
            final hadArchive = File(
              store.archivePath(target.checksum),
            ).existsSync();
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
              final alias = p.join(manifestFile.parent.path, relative);

              await Directory(p.dirname(alias)).create(recursive: true);
              try {
                final existed =
                    FileSystemEntity.typeSync(alias, followLinks: false) !=
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
              final destination = p.join(manifestFile.parent.path, relative);
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
            await write(manifestFile.path, utf8.encode(rewritten));
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
          await filesystem.stampByContent(manifestFile.path, rewritten);
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
    SwiftPmArtifactCopyPolicy? materializeCopyPolicy,
  }) async {
    final key = binaryArtifactAttemptKey(provenance);
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
    final copy =
        materialize ??
        preparer.materializeBinaryArtifact;
    if (packageLocalArtifactJunctionCapability) {
      try {
        final started = Stopwatch()..start();
        await create(alias: destination, target: preparedArtifactPath);
        filesystem.traceBinaryOperation(
          target: provenance.target.name,
          operation: 'recover',
          extractedBytes: filesystem.directoryBytes(
            preparedArtifactPath,
          ),
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
    final artifacts = Directory(artifactsRoot);
    final vendor = Directory(vendorDir);
    final checkouts = Directory(p.join(scratchPath, 'checkouts'));
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
          final provenance = SwiftPmBinaryRecovery.scanBinaryArtifactProvenance(
            packageIdentity: packageIdentity,
            manifestPath: entity.path,
            manifest: manifest,
          );
          for (final candidate in provenance.reversed) {
            final targetDirectory = Directory(
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
                final extractedStore = p.join(binaryArtifactFallback, 'extracted-artifacts');
                final store = Directory(extractedStore);
                await store.create(recursive: true);
                final staging = await store.createTemp('.extracted-');
                try {
                  final artifactName = p.basename(extracted.single.path);
                  final retainedNames = libraryIdentifiers(extracted.single);
                  if (retainedNames.isEmpty) continue;
                  await filesystem.copyResolvedArtifactTree(
                    extracted.single.path,
                    p.join(staging.path, artifactName),
                    includeTopLevel: (name) =>
                        name == 'Info.plist' || retainedNames.contains(name),
                  );

                  final artifactPath = await SwiftPmOfflineArtifactPublisher(
                    fileSystem: artifactFileSystem,
                    publicationCoordinator: publicationCoordinator,
                  ).publish(
                    stagingRoot: staging,
                    destination: p.join(extractedStore, candidate.target.checksum, candidate.target.name),
                    artifactDirectoryName: artifactName,
                  );
                  verified.add(SwiftPmBinaryArtifactEntry(
                    archiveChecksum: candidate.target.checksum,
                    targetName: candidate.target.name,
                    artifactPath: artifactPath,
                  ));
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
                FileSystemEntity.typeSync(destination, followLinks: false) !=
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
              publication = await recoverFinalBinaryArtifact(
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

  static Map<String, String> dependencyRefsFromPackageResolved(String output) {
    final resolved = jsonDecode(output) as Map<String, dynamic>;
    return {
      for (final pinValue in resolved['pins'] as List<dynamic>? ?? const [])
        if (pinValue case {
          'location': final String location,
          'state': {'revision': final String revision},
        })
          SwiftPmBinaryRecovery.canonicalGitUrl(location): revision,
    };
  }

  static String canonicalGitUrl(String url) {
    var canonical = url.replaceFirst(RegExp(r'/+$'), '');
    if (canonical.toLowerCase().endsWith('.git')) {
      canonical = canonical.substring(0, canonical.length - 4);
    }
    final parsed = Uri.tryParse(canonical);
    if (parsed == null || !parsed.hasScheme) return canonical;
    return parsed
        .replace(
          scheme: parsed.scheme.toLowerCase(),
          host: parsed.host.toLowerCase(),
        )
        .toString();
  }

  Future<String> dependencyEvaluationKey(
    String manifest,
    String packageDirectory,
  ) async {
    final variants = <String>[];
    final directory = Directory(packageDirectory);
    if (directory.existsSync()) {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('Package@') && name.endsWith('.swift')) {
          variants.add('$name\u0000${await entity.readAsString()}');
        }
      }
    }
    variants.sort();
    return sha256
        .convert(
          utf8.encode(
            [
              'xcross-dependency-evaluation-v1',
              manifest,
              ...variants,
            ].join('\u0000'),
          ),
        )
        .toString();
  }

  static List<SwiftPmBinaryArtifactProvenance> scanBinaryArtifactProvenance({
    required String packageIdentity,
    required String manifestPath,
    required String manifest,
  }) => [
    for (final target in SwiftPmBinaryTargetManifest.discover(manifest))
      SwiftPmBinaryArtifactProvenance(
        packageIdentity: packageIdentity,
        target: target,
        manifestPath: manifestPath,
      ),
  ];

  SwiftPmBinaryArtifactProvenance? matchBinaryArtifactProvenance({
    required String artifactPath,
    required String artifactsRoot,
    required Iterable<SwiftPmBinaryArtifactProvenance> provenance,
  }) {
    final relative = p.split(p.relative(artifactPath, from: artifactsRoot));
    if (relative.length < 2 || swiftPmComponent(relative.first) == 'extract') {
      return null;
    }
    final identity = swiftPmComponent(relative[0]);
    final target = swiftPmComponent(relative[1]);
    final matches = provenance
        .where(
          (candidate) =>
              swiftPmComponent(candidate.packageIdentity) == identity &&
              swiftPmComponent(candidate.target.name) == target,
        )
        .toList();
    return matches.length == 1 ? matches.single : null;
  }

  String swiftPmComponent(String value) => hostPolicy.artifactIdentity(value);

  String binaryArtifactAttemptKey(SwiftPmBinaryArtifactProvenance provenance) =>
      [
        swiftPmComponent(provenance.packageIdentity),
        swiftPmComponent(provenance.target.name),
        provenance.target.checksum.toLowerCase(),
      ].join('\u0000');

  /// Manifest files tracked anywhere in a SwiftPM checkout, without walking
  /// its working tree. Git for Windows handles its index with
  /// `core.longpaths=true`, so irrelevant deep assets cannot make discovery
  /// fail with MAX_PATH.
  Future<List<File>> trackedPackageManifestFiles(
    String packageDirectory, {
    Future<CapturedProcess> Function(String, List<String>)? runProcess,
  }) async {
    final result = await (runProcess ?? runner.run)('git', [
      '-c',
      'core.longpaths=true',
      '-C',
      packageDirectory,
      'ls-files',
      '-z',
      '--',
      'Package.swift',
      'Package@*.swift',
      ':(glob)**/Package.swift',
      ':(glob)**/Package@*.swift',
    ]);
    if (result.exitCode != 0) {
      throw FlutterBuildError(
        'Could not inspect SwiftPM checkout $packageDirectory: '
        '${result.stderr.trim()}',
      );
    }
    final paths =
        result.stdout
            .split('\u0000')
            .where((path) => path.isNotEmpty)
            .map((path) => File(p.join(packageDirectory, p.fromUri(path))))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return paths;
  }

  static List<File> rootPackageManifestFiles(String packageDirectory) {
    final root = Directory(packageDirectory);
    if (!root.existsSync()) return const [];
    final files = root.listSync(followLinks: false).whereType<File>().where((
      file,
    ) {
      final name = p.basename(file.path);
      return name == 'Package.swift' ||
          (name.startsWith('Package@') && name.endsWith('.swift'));
    }).toList()..sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  Future<List<SwiftPmBinaryArtifactProvenance>> binaryArtifactProvenance(
    String packageDirectory,
    String scratchPath,
    List<SwiftPmPackageDependency> dependencies,
  ) async {
    final result = <SwiftPmBinaryArtifactProvenance>[];
    final packageRoot = Directory(packageDirectory);
    final checkoutRoot = p.join(scratchPath, 'checkouts');
    final roots = <String, String?>{packageRoot.path: null};
    for (final dependency in dependencies) {
      roots[p.join(checkoutRoot, dependency.identity)] = dependency.identity;
      roots[p.join(
            checkoutRoot,
            SwiftPmManifestDependencies.packageIdentityFromUrl(dependency.url),
          )] =
          dependency.identity;
    }
    for (final entry in roots.entries) {
      if (!Directory(entry.key).existsSync()) continue;
      final manifests = entry.value == null
          ? SwiftPmBinaryRecovery.rootPackageManifestFiles(entry.key)
          : await trackedPackageManifestFiles(entry.key);
      for (final entity in manifests) {
        final manifest = await entity.readAsString();
        final declaredName = RegExp(
          r'Package\s*\(\s*name\s*:\s*"([^"]+)"',
        ).firstMatch(manifest)?.group(1);
        final identity = entry.value ?? declaredName;
        if (identity == null) continue;
        result.addAll(
          SwiftPmBinaryRecovery.scanBinaryArtifactProvenance(
            packageIdentity: identity,
            manifestPath: entity.path,
            manifest: manifest,
          ),
        );
      }
    }
    return result;
  }

  Future<bool> recoverBootstrapBinaryArtifacts({
    required String scratchPath,
    required String binaryArtifactStore,
    required Iterable<SwiftPmBinaryArtifactProvenance> provenance,
    required SwiftPmBinaryAttemptState attemptState,

    bool swiftPmArtifactJunctionCapability = false,
  }) async {
    final artifactsRoot = p.join(scratchPath, 'artifacts');
    final artifacts = Directory(artifactsRoot);
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
          swiftPmComponent(p.basename(package.path)) == 'extract') {
        continue;
      }
      for (final targetDirectory in package.listSync(followLinks: false)) {
        if (targetDirectory is! Directory) continue;
        final match = matchBinaryArtifactProvenance(
          artifactPath: targetDirectory.path,
          artifactsRoot: artifactsRoot,
          provenance: provenance,
        );
        if (match == null) continue;
        final key = binaryArtifactAttemptKey(match);
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
      final key = binaryArtifactAttemptKey(candidate.provenance);
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
        if (await hasCompleteSwiftPmArtifact(artifact)) {
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

  Set<String> libraryIdentifiers(Directory artifact) {
    final fallback = {for(final id in targetPolicy.engineSliceIdentifiers) if(Directory(p.join(artifact.path,id)).existsSync()) id};
    final info = File(p.join(artifact.path, 'Info.plist'));
    try {
      final plist = PropertyListSerialization.propertyListWithString(
        info.readAsStringSync(),
      );
      if (plist is! Map || plist['AvailableLibraries'] is! List) return fallback;
      return {
        for (final library in plist['AvailableLibraries'] as List)
          if (library is Map &&
              library['SupportedPlatform'] == 'ios' &&
              targetPolicy.matchesLibraryVariant(
                library['SupportedPlatformVariant'] as String?,
              ) &&
              library['SupportedArchitectures'] is List &&
              (library['SupportedArchitectures'] as List).contains('arm64') &&
              library['LibraryIdentifier'] is String)
            library['LibraryIdentifier'] as String,
      };
    } on Object {
      return fallback;
    }
  }

  Future<bool> hasCompleteSwiftPmArtifact(Directory artifact) async {
    final info = File(p.join(artifact.path, 'Info.plist'));
    if (!info.existsSync()) return false;
    try {
      final value = PropertyListSerialization.propertyListWithString(
        await info.readAsString(),
      );
      if (value is! Map) return false;
      final libraries = value['AvailableLibraries'];
      if (libraries is! List) return false;
      for (final value in libraries) {
        if (value is! Map ||
            value['SupportedPlatform'] != 'ios' ||
            !targetPolicy.matchesLibraryVariant(
              value['SupportedPlatformVariant'] as String?,
            )) {
          continue;
        }
        final architectures = value['SupportedArchitectures'];
        final identifier = value['LibraryIdentifier'];
        final libraryPath = value['LibraryPath'];
        if (architectures is! List ||
            !architectures.contains('arm64') ||
            identifier is! String ||
            identifier.isEmpty ||
            libraryPath is! String ||
            libraryPath.isEmpty) {
          continue;
        }
        if (FileSystemEntity.typeSync(
              p.join(artifact.path, identifier, libraryPath),
            ) !=
            FileSystemEntityType.notFound) {
          return true;
        }
      }
    } on Object {
      return false;
    }
    return false;
  }

  Future<Map<String, String>> evaluateDependencyRefsWithRecovery(
    String packageDirectory, {
    required Future<void> Function(String packageDirectory) resolve,
    required Future<bool> Function(
      String packageDirectory,
      SwiftPmBinaryAttemptState attemptState,
    )
    recover,
    required SwiftPmBinaryAttemptState attemptState,
  }) async {
    final resolvedFile = File(p.join(packageDirectory, 'Package.resolved'));
    if (resolvedFile.existsSync()) await resolvedFile.delete();
    try {
      await resolve(packageDirectory);
    } on Object {
      if (!await recover(packageDirectory, attemptState)) rethrow;
      await resolve(packageDirectory);
    }
    try {
      return SwiftPmBinaryRecovery.dependencyRefsFromPackageResolved(
        await resolvedFile.readAsString(),
      );
    } on Object catch (error) {
      throw FlutterBuildError('Cannot read ${resolvedFile.path}: $error');
    }
  }

  static String? dependencyResolverScratchPath({
    required String packageDirectory,
    required String? scratchPath,
    required bool usesDefaultResolver,
  }) => usesDefaultResolver ? p.join(packageDirectory, '.build') : scratchPath;

  Future<Map<String, String>> evaluatedDependencyRefs(
    String packageDirectory,
    Future<String> Function(String name) locateTool, {
    Future<void> Function(String packageDirectory)? resolve,
    Future<bool> Function(
      String packageDirectory,
      SwiftPmBinaryAttemptState attemptState,
    )?
    recover,
    SwiftPmBinaryAttemptState? attemptState,
    String? scratchPath,
    String? binaryArtifactStore,

    String? binaryArtifactFallback,
    bool swiftPmArtifactJunctionCapability = false,
    List<SwiftPmPackageDependency> dependencies = const [],
  }) async {
    final swift = await locateTool(hostPolicy.packageTool);
    final runResolve =
        resolve ??
        (directory) => retryingTransientNetworkFailure(
          () => sourceRepair.resolveOnce(swift, directory),
          label: 'swift package resolve',
        );
    // `swift package --package-path <directory> resolve` uses
    // `<directory>/.build`; it does not share the final build's explicit
    // scratch path. Recovery must inspect the checkouts and artifacts from
    // this resolver invocation, not `workspace.scratch`.
    final resolverScratchPath =
        SwiftPmBinaryRecovery.dependencyResolverScratchPath(
          packageDirectory: packageDirectory,
          scratchPath: scratchPath,
          usesDefaultResolver: resolve == null,
        );
    final canRecover =
        resolverScratchPath != null &&
        binaryArtifactStore != null &&
        binaryArtifactFallback != null;
    return evaluateDependencyRefsWithRecovery(
      packageDirectory,
      resolve: runResolve,
      recover:
          recover ??
          (_, state) async {
            if (!canRecover) return false;
            return dependencyPreparation.recoverArtifacts(SwiftPmDependencyArtifactRecoveryRequest(recovery:this,interopRepair:interopRepair,packageRoot:packageDirectory,scratchPath:resolverScratchPath,store:binaryArtifactStore,fallback:binaryArtifactFallback,dependencies:dependencies,state:state,capability:swiftPmArtifactJunctionCapability));
          },
      attemptState: attemptState ?? SwiftPmBinaryAttemptState(),
    );
  }
}
