import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/resource_manifest.dart';

@internal
final class FlutterFrameworkCopier {
  FlutterFrameworkCopier(this.fileSystem, this.paths, {required this.copier});
  final RecursiveDirectoryCopier copier;

  final HostFileSystemInterface fileSystem;
  final p.Context paths;

  /// Copies every SwiftPM-produced dylib into the app's Frameworks directory.
  Future<void> copyPluginLibraries(
    Iterable<String> pluginLibraries,
    String frameworksDir,
  ) async {
    for (final library in pluginLibraries) {
      await fileSystem
          .file(library)
          .copy(
            fileSystem
                .file(paths.join(frameworksDir, paths.basename(library)))
                .path,
          );
    }
  }

  /// Copies every native-asset framework into the app's Frameworks directory.
  Future<void> copyNativeAssetFrameworks(
    Iterable<String> frameworks,
    String frameworksDir,
  ) async {
    for (final framework in frameworks) {
      await copier.copy(
        framework,
        paths.join(frameworksDir, paths.basename(framework)),
      );
    }
  }

  Future<List<String>> copyMissingFrameworks(
    Iterable<String> frameworks,
    String frameworksDir,
  ) async {
    final copied = <String>[];
    for (final framework in frameworks) {
      final destination = paths.join(frameworksDir, paths.basename(framework));
      if (fileSystem.directory(destination).existsSync()) continue;
      await copier.copy(framework, destination);
      copied.add(destination);
    }
    return copied;
  }

  /// Copies SwiftPM resource bundles (`<Package>_<Target>.bundle`) into the
  /// application root, where Xcode places them and where SwiftPM's generated
  /// `Bundle.module` accessor looks (`Bundle.main.bundleURL`). Must run
  /// before signing so the bundles are sealed into the app's resources.
  ///
  /// Measured with Xcode 26.6: Xcode copies every declared resource from its
  /// source with `builtin-copy -exclude .DS_Store -exclude CVS -exclude .svn
  /// -exclude .git -exclude .hg -resolve-src-symlinks`. A resource that is
  /// itself a link (`.copy` or `.process`) becomes a real copy of its
  /// target. A resource directory is copied with its contents as they are:
  /// a link inside it stays a link, which works when it points inside the
  /// bundle and dangles when it escapes it.
  ///
  /// `swift build` instead copies the link itself, and its relative target
  /// is relative to the source, so every linked resource dangles in the
  /// built bundle. SDWebImage's `.copy("Resources/PrivacyInfo.xcprivacy")`
  /// is such a link (to `../../WebImage/PrivacyInfo.xcprivacy`); package
  /// checkouts keep their links (see `checkout_links.dart`).
  ///
  /// So, when SwiftPM's build manifest names the resources of a bundle
  /// ([SwiftPmResourceBundle.resources]), each one is copied from its source
  /// the way Xcode does, and the files SwiftPM generated itself (such as
  /// `Info.plist`) are copied from the built bundle. One deliberate
  /// difference: a link inside a resource directory that escapes the bundle
  /// is copied as its target (resolved from the source), because codesign
  /// and installd reject dangling links, and is skipped with a warning when
  /// that target does not exist. Without a manifest the built bundle is
  /// copied, resolving the links that resolve and warning about the rest.
  ///
  /// Xcode also writes an `Info.plist` into every SwiftPM resource bundle
  /// (`ProcessInfoPlistFile` with product type
  /// `com.apple.product-type.bundle`); `swift build` on Linux and Windows
  /// does not. A bundle that has none after copying gets [infoPlist]'s.
  Future<List<String>> copyResourceBundles(
    Iterable<SwiftPmResourceBundle> bundles,
    String bundleDir, {
    void Function(String message)? warn,
    String Function(SwiftPmResourceBundle bundle)? infoPlist,
  }) async {
    final copied = <String>[];
    for (final resourceBundle in bundles) {
      final bundle = resourceBundle.bundlePath;
      final destination = paths.join(bundleDir, paths.basename(bundle));
      if (fileSystem.directory(destination).existsSync()) continue;
      await fileSystem.directory(destination).create(recursive: true);
      final resources =
          resourceBundle.resources ?? const <SwiftPmBundleResource>[];
      final covered = {
        for (final resource in resources) paths.normalize(resource.relative),
      };
      if (fileSystem.directory(bundle).existsSync()) {
        await _copyGenerated(bundle, destination, bundle, covered, warn);
      }
      for (final resource in resources) {
        await _copyFromSource(
          resource.source,
          paths.join(destination, resource.relative),
          bundleRoot: destination,
          warn: warn,
        );
      }
      final plist = fileSystem.file(paths.join(destination, 'Info.plist'));
      if (infoPlist != null && !plist.existsSync()) {
        await plist.writeAsString(infoPlist(resourceBundle));
      }
      copied.add(destination);
    }
    return copied;
  }

  static const _excluded = {'.DS_Store', 'CVS', '.svn', '.git', '.hg'};

  /// Copies what the built [bundle] holds outside the [covered] resources.
  Future<void> _copyGenerated(
    String directory,
    String destination,
    String bundle,
    Set<String> covered,
    void Function(String message)? warn,
  ) async {
    await for (final entity
        in fileSystem.directory(directory).list(followLinks: false)) {
      final relative = paths.relative(entity.path, from: bundle);
      if (covered.contains(relative)) continue;
      final target = paths.join(destination, paths.basename(entity.path));
      final holdsResource = covered.any(
        (resource) => paths.isWithin(relative, resource),
      );
      if (holdsResource &&
          !fileSystem.link(entity.path).existsSync() &&
          fileSystem.directory(entity.path).existsSync()) {
        await fileSystem.directory(target).create(recursive: true);
        await _copyGenerated(entity.path, target, bundle, covered, warn);
        continue;
      }
      await _copyResource(
        entity.path,
        target,
        bundleRoot: bundle,
        topLevel: true,
        warn: warn,
      );
    }
  }

  /// Copies one declared resource from its [source] like Xcode's
  /// `builtin-copy -resolve-src-symlinks`.
  Future<void> _copyFromSource(
    String source,
    String destination, {
    required String bundleRoot,
    required void Function(String message)? warn,
  }) async {
    var path = source;
    if (fileSystem.link(source).existsSync()) {
      try {
        path = fileSystem.file(source).resolveSymbolicLinksSync();
      } on FileSystemException {
        warn?.call(
          'Skipping ${paths.basename(source)} in '
          '${paths.basename(bundleRoot)}: it links to '
          '${fileSystem.link(source).targetSync()}, which does not exist.',
        );
        return;
      }
    }
    if (fileSystem.directory(path).existsSync()) {
      await _copySourceDirectory(
        path,
        destination,
        bundleRoot: bundleRoot,
        warn: warn,
        visited: {fileSystem.directory(path).resolveSymbolicLinksSync()},
      );
    } else if (fileSystem.file(path).existsSync()) {
      await fileSystem
          .directory(paths.dirname(destination))
          .create(recursive: true);
      await fileSystem.file(path).copy(fileSystem.file(destination).path);
    } else {
      warn?.call(
        'Skipping ${paths.basename(source)} in '
        '${paths.basename(bundleRoot)}: $source does not exist.',
      );
    }
  }

  Future<void> _copySourceDirectory(
    String source,
    String destination, {
    required String bundleRoot,
    required void Function(String message)? warn,
    required Set<String> visited,
  }) async {
    await fileSystem.directory(destination).create(recursive: true);
    await for (final entity
        in fileSystem.directory(source).list(followLinks: false)) {
      final name = paths.basename(entity.path);
      if (_excluded.contains(name)) continue;
      final target = paths.join(destination, name);
      var path = entity.path;
      if (fileSystem.link(path).existsSync()) {
        final linkTarget = fileSystem.link(path).targetSync();
        final inBundle =
            !paths.isAbsolute(linkTarget) &&
            paths.isWithin(
              bundleRoot,
              paths.normalize(paths.join(destination, linkTarget)),
            );
        final resolvesAtSource =
            fileSystem.file(path).existsSync() ||
            fileSystem.directory(path).existsSync();
        if (inBundle && resolvesAtSource) {
          try {
            await fileSystem.link(target).create(linkTarget);
            continue;
          } on FileSystemException {
            // No symlink rights (Windows): copy what it points at instead.
          }
        }
        try {
          path = fileSystem.file(path).resolveSymbolicLinksSync();
        } on FileSystemException {
          warn?.call(
            'Skipping $name in ${paths.basename(bundleRoot)}: it links to '
            '$linkTarget, which does not exist.',
          );
          continue;
        }
      }
      if (fileSystem.directory(path).existsSync()) {
        final canonical = fileSystem.directory(path).resolveSymbolicLinksSync();
        if (!visited.add(canonical)) {
          warn?.call(
            'Skipping $name in ${paths.basename(bundleRoot)}: its links form '
            'a cycle.',
          );
          continue;
        }
        await _copySourceDirectory(
          path,
          target,
          bundleRoot: bundleRoot,
          warn: warn,
          visited: visited,
        );
        visited.remove(canonical);
      } else if (fileSystem.file(path).existsSync()) {
        await fileSystem.file(path).copy(fileSystem.file(target).path);
      }
    }
  }

  Future<void> _copyResource(
    String source,
    String destination, {
    required String bundleRoot,
    required bool topLevel,
    required void Function(String message)? warn,
    Set<String>? visited,
  }) async {
    visited ??= <String>{};
    var path = source;
    if (fileSystem.link(source).existsSync()) {
      final target = fileSystem.link(source).targetSync();
      final resolved = paths.normalize(
        paths.isAbsolute(target)
            ? target
            : paths.join(paths.dirname(source), target),
      );
      final staysInBundle =
          !paths.isAbsolute(target) && paths.isWithin(bundleRoot, resolved);
      if (!topLevel && staysInBundle) {
        try {
          await fileSystem.link(destination).create(target);
          return;
        } on FileSystemException {
          // A Windows host without symlink rights: fall through and copy
          // what the link points at, which keeps the content identical.
        }
      }
      if (!fileSystem.file(resolved).existsSync() &&
          !fileSystem.directory(resolved).existsSync()) {
        warn?.call(
          'Skipping ${paths.basename(source)} in '
          '${paths.basename(bundleRoot)}: it links to $target, which does '
          'not exist.',
        );
        return;
      }
      path = resolved;
    }
    if (fileSystem.directory(path).existsSync()) {
      // A link cycle (a directory linking to an ancestor) would never end.
      final canonical = fileSystem.directory(path).resolveSymbolicLinksSync();
      if (!visited.add(canonical)) {
        warn?.call(
          'Skipping ${paths.basename(source)} in '
          '${paths.basename(bundleRoot)}: its links form a cycle.',
        );
        return;
      }
      await fileSystem.directory(destination).create(recursive: true);
      await for (final entity
          in fileSystem.directory(path).list(followLinks: false)) {
        await _copyResource(
          entity.path,
          paths.join(destination, paths.basename(entity.path)),
          // A directory reached through a link is copied as-is, so links
          // inside it are judged against that directory, not the bundle.
          bundleRoot: path == source ? bundleRoot : path,
          topLevel: false,
          warn: warn,
          visited: visited,
        );
      }
      visited.remove(canonical);
    } else if (fileSystem.file(path).existsSync()) {
      await fileSystem.file(path).copy(fileSystem.file(destination).path);
    }
  }
}
