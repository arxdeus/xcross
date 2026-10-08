import 'dart:async';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/binary_preparation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_source_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_lexer.dart';

@internal
const String flutterFrameworkPackageName = 'FlutterFramework';

@internal
final class SwiftPmPluginOverlay<T extends PlatformHostInterface> {
  SwiftPmPluginOverlay({
    required this.filesystem,
    required this.sourceNormalizer,
    required this.binaryPreparation,
    required this.manifestPolicy,
  });
  static const iosUnreachableEntries = {
    // development trees
    '.dart_tool',
    '.git',
    '.github',
    'build',
    'example',
    'test',
    'tests',
    // dart code and pub metadata
    'lib',
    'pubspec.yaml',
    'pubspec.lock',
    'analysis_options.yaml',
    'readme.md',
    'changelog.md',
    // other platforms ('darwin' stays: it is shared with iOS)
    'android',
    'macos',
    'windows',
    'linux',
    'web',
    // pigeon input definitions: consumed by the pigeon generator at
    // development time, never referenced by the generated iOS build
    'pigeons',
  };
  final SwiftPmVendoredManifestPolicy manifestPolicy;
  final SwiftPmBinaryPreparation<T> binaryPreparation;
  final SwiftPmFilesystem<T> filesystem;
  final SwiftPmHostSourceNormalizer sourceNormalizer;

  /// Stages [target] at [alias], using a shallow overlay when the Swift
  /// manifest needs host fixes (linker flags, Windows CRT imports).
  ///
  /// [platformDir] is the package-root subdirectory [target] sits in — `ios`
  /// normally, `darwin` for shared-source Apple plugins. The staged tree keeps
  /// the same shape so relative paths inside the plugin's `Package.swift`
  /// (`../../src`, shared header search paths) still resolve.
  Future<String> stagePluginPackage({
    required String alias,
    required String target,
    String platformDir = 'ios',
    Map<String, String> packageTargets = const {},
    bool copySources = false,
    Map<String, List<String>> fallbackSwiftModules = const {},
    String? scratchPath,
    String? binaryArtifactStore,
    String? binaryArtifactFallback,
    bool swiftPmArtifactJunctionCapability = false,
    bool packageLocalArtifactJunctionCapability = false,
  }) async {
    var stagedPackage = alias;
    if (copySources) {
      await filesystem.deleteUnless(alias, FileSystemEntityType.directory);
      final packageRoot = p.dirname(p.dirname(target));
      await stageAncestorOverlay(
        sourceRoot: packageRoot,
        destinationRoot: alias,
        packageName: p.basename(target),
        platformDir: platformDir,
      );
      await filesystem.createDirectoryAlias(
        p.join(alias, platformDir, flutterFrameworkPackageName),
        p.join(p.dirname(alias), flutterFrameworkPackageName),
      );
      stagedPackage = p.join(alias, platformDir, p.basename(target));
    }

    final manifest = await filesystem.artifactFileSystem
        .file(p.join(target, 'Package.swift'))
        .readAsString();
    var normalizedManifest = sourceNormalizer.removeMissingResources(
      manifestPolicy.normalizeHostManifest(manifest),
      target,
    );
    for (final call in SwiftPmManifestLexer.swiftCalls(
      normalizedManifest,
      '.package',
    ).reversed) {
      final relativePath = SwiftPmManifestLexer.namedString(call.text, 'path');
      if (relativePath == null || p.isAbsolute(relativePath)) continue;
      final dependencyName =
          SwiftPmManifestLexer.namedString(call.text, 'name') ??
          p.basename(relativePath);
      final targetPath = packageTargets[dependencyName];
      if (targetPath == null) continue;
      final rewritten = call.text.replaceFirst(
        RegExp(r'path\s*:\s*"[^"]+"'),
        'path: "${SwiftPmFilesystem.swiftPath(targetPath)}"',
      );
      normalizedManifest = normalizedManifest.replaceRange(
        call.start,
        call.end,
        rewritten,
      );
    }
    if (copySources) {
      // Normalizing during the mirror keeps re-runs byte-stable: copying
      // first and normalizing after would rewrite (and re-timestamp) every
      // normalized source on every build.
      await mirrorPluginPackage(
        target,
        stagedPackage,
        normalizedManifest,
        transform: hostSwiftTransform(fallbackSwiftModules),
      );
    } else if (normalizedManifest == manifest) {
      await filesystem.createDirectoryAlias(stagedPackage, target);
      await sourceNormalizer.normalizeHostSwiftTree(
        stagedPackage,
        fallbackSwiftModules: fallbackSwiftModules,
      );
    } else {
      await overlayPluginManifest(target, stagedPackage, normalizedManifest);
      await sourceNormalizer.normalizeHostSwiftTree(
        stagedPackage,
        fallbackSwiftModules: fallbackSwiftModules,
      );
    }
    if (binaryArtifactStore != null && binaryArtifactFallback != null) {
      await binaryPreparation.prepareSupportedBinaryArtifacts(
        packageRoot: stagedPackage,
        binaryArtifactStore: binaryArtifactStore,
        binaryArtifactFallback: binaryArtifactFallback,
        packageLocalArtifactJunctionCapability:
            packageLocalArtifactJunctionCapability,
      );
    }

    return stagedPackage;
  }

  /// Mirrors [target] at [staged] with [manifest] as its `Package.swift`.
  ///
  /// Only differing files are rewritten, so a rebuild presents SwiftPM with
  /// the timestamps it already compiled and its incremental state stays
  /// warm.
  Future<void> mirrorPluginPackage(
    String target,
    String staged,
    String manifest, {
    SwiftPmSourceTransform? transform,
  }) async {
    await filesystem.deleteUnless(staged, FileSystemEntityType.directory);
    await filesystem.syncDirectory(
      target,
      staged,
      preserve: const {'Package.swift'},
      transform: transform,
    );
    await filesystem.writeStable(p.join(staged, 'Package.swift'), manifest);
    // The manifest is regenerated from the plugin's own each build and can
    // legitimately differ between the staging write and a later pass, so
    // "write only when changed" cannot keep its timestamp fixed on its own.
    // SwiftPM invalidates a package's whole target set on its manifest
    // timestamp, so stamp by content: identical output keeps the timestamp
    // SwiftPM already compiled against.
    await filesystem.stampByContent(p.join(staged, 'Package.swift'), manifest);
  }

  /// The host-compatibility source rewrite as a sync transform, electing
  /// Swift sources but never package manifests or binary files.
  SwiftPmSourceTransform hostSwiftTransform(
    Map<String, List<String>> fallbackSwiftModules,
  ) => (path) {
    final name = p.basename(path);
    final isManifest =
        name == 'Package.swift' ||
        (name.startsWith('Package@') && name.endsWith('.swift'));
    if (p.extension(name) != '.swift' || isManifest) return null;
    return (content) => SwiftPmHostSourceNormalizer.normalizeHostSwiftSource(
      content,
      fallbackSwiftModules: fallbackSwiftModules,
    );
  };

  /// Stages [target] at [staged] as per-entry aliases beneath a rewritten
  /// `Package.swift`, for hosts where symbolic links are first-class.
  Future<void> overlayPluginManifest(
    String target,
    String staged,
    String manifest,
  ) async {
    await filesystem.deleteEntity(staged);
    await filesystem.artifactFileSystem
        .directory(staged)
        .create(recursive: true);
    await filesystem.writeStable(p.join(staged, 'Package.swift'), manifest);
    await for (final entity
        in filesystem.artifactFileSystem
            .directory(target)
            .list(followLinks: false)) {
      if (p.basename(entity.path) == 'Package.swift') continue;
      await stageEntity(
        entity,
        p.join(staged, p.basename(entity.path)),
        copyDirectories: false,
      );
    }
  }

  Future<void> stageAncestorOverlay({
    required String sourceRoot,
    required String destinationRoot,
    required String packageName,
    String platformDir = 'ios',
  }) async {
    await filesystem.artifactFileSystem
        .directory(p.join(destinationRoot, platformDir))
        .create(recursive: true);
    final staged = <String>{platformDir};
    await for (final entity
        in filesystem.artifactFileSystem
            .directory(sourceRoot)
            .list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name == platformDir ||
          iosUnreachableEntries.contains(name.toLowerCase())) {
        continue;
      }
      staged.add(name);
      await stageEntity(
        entity,
        p.join(destinationRoot, name),
        copyDirectories: true,
        excludedSourcePath: destinationRoot,
      );
    }
    await pruneUnexpected(destinationRoot, staged);

    final stagedIos = <String>{packageName, flutterFrameworkPackageName};
    await for (final entity
        in filesystem.artifactFileSystem
            .directory(p.join(sourceRoot, platformDir))
            .list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name == packageName || name == flutterFrameworkPackageName) continue;
      stagedIos.add(name);
      await stageEntity(
        entity,
        p.join(destinationRoot, platformDir, name),
        copyDirectories: true,
        excludedSourcePath: destinationRoot,
      );
    }
    await pruneUnexpected(p.join(destinationRoot, platformDir), stagedIos);
  }

  /// Deletes entries of [directory] not named in [expected], so previously
  /// staged files that no longer qualify do not linger in the build tree.
  Future<void> pruneUnexpected(String directory, Set<String> expected) async {
    await for (final entity
        in filesystem.artifactFileSystem
            .directory(directory)
            .list(followLinks: false)) {
      if (!expected.contains(p.basename(entity.path))) {
        await filesystem.deleteEntity(entity.path);
      }
    }
  }

  Future<void> stageEntity(
    FileSystemEntity entity,
    String destination, {
    required bool copyDirectories,
    String? excludedSourcePath,
  }) async {
    final resolved = entity is Link
        ? filesystem.artifactFileSystem.processPath(
            entity.resolveSymbolicLinksSync(),
          )
        : filesystem.artifactFileSystem.processPath(entity.path);
    if (!filesystem.artifactFileSystem.directory(resolved).existsSync()) {
      await filesystem.syncFile(
        filesystem.artifactFileSystem.file(resolved),
        destination,
      );
    } else if (copyDirectories) {
      await filesystem.syncDirectory(
        resolved,
        destination,
        excludedSourcePath: excludedSourcePath,
      );
    } else {
      await filesystem.createDirectoryAlias(destination, resolved);
    }
  }
}
