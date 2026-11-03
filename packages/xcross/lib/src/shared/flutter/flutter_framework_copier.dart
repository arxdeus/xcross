import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/apple/interface_builder/xib_compiler.dart';
import 'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dynamic_product.dart';
import 'package:xcross/src/shared/flutter/swiftpm/resource_manifest.dart';

@internal
final class FlutterFrameworkCopier {
  FlutterFrameworkCopier(
    this.fileSystem,
    this.paths, {
    required this.copier,
    XibCompile? compileXib,
  }) : compileXib = compileXib ?? const XibCompiler().compile;
  final RecursiveDirectoryCopier copier;

  /// Compiles the `.xib` resources Xcode would compile into `.nib`
  /// ([XibCompiler.compile] unless a test injects another).
  final XibCompile compileXib;

  final HostFileSystemInterface fileSystem;
  final p.Context paths;

  /// Embeds every SwiftPM-produced dylib in the app's Frameworks directory as
  /// `<Product>.framework/<Product>` with the `Info.plist` [infoPlist] gives
  /// it, as Xcode embeds a dynamic SwiftPM product: the App Store rejects a
  /// loose dylib there (ITMS-90171). The dylib already carries the
  /// framework's install name (see `SwiftPmAssembly`). Returns the
  /// frameworks it wrote.
  Future<List<String>> copyPluginLibraries(
    Iterable<SwiftPmDynamicProduct> products,
    String frameworksDir, {
    required String Function(SwiftPmDynamicProduct product) infoPlist,
  }) async {
    final written = <String>[];
    for (final product in products) {
      final framework = paths.join(frameworksDir, product.frameworkName);
      await fileSystem.directory(framework).create(recursive: true);
      await fileSystem
          .file(product.libraryPath)
          .copy(fileSystem.file(paths.join(framework, product.name)).path);
      await fileSystem
          .file(paths.join(framework, 'Info.plist'))
          .writeAsString(infoPlist(product));
      written.add(framework);
    }
    return written;
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
      await stripEmbeddedHeaders(destination);
      copied.add(destination);
    }
    return copied;
  }

  /// Directories Xcode's "Embed Frameworks" phase removes from an embedded
  /// framework (`REMOVE_HEADERS_FROM_EMBEDDED_BUNDLES=YES`).
  static const embeddedHeaderDirectories = {
    'Headers',
    'PrivateHeaders',
    'Modules',
  };

  /// Removes [embeddedHeaderDirectories] from [framework], as Xcode 26.6
  /// does for every SwiftPM binary framework it embeds (the native
  /// `GoogleCast.framework` ships without `Headers/` and `Modules/`).
  /// `Flutter.framework` is left alone: Flutter's own embed step copies it
  /// whole, and the native app keeps its `Headers/` and `Modules/`.
  /// `_CodeSignature` is not touched; it is resealed at signing.
  Future<void> stripEmbeddedHeaders(String framework) async {
    if (paths.basename(framework) == 'Flutter.framework') return;
    for (final name in embeddedHeaderDirectories) {
      final path = paths.join(framework, name);
      if (fileSystem.link(path).existsSync()) {
        await fileSystem.link(path).delete();
      } else if (fileSystem.directory(path).existsSync()) {
        await fileSystem.directory(path).delete(recursive: true);
      }
    }
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
  /// does not, except for a package that declares `defaultLocalization`,
  /// where SwiftPM writes a partial one holding only
  /// `CFBundleDevelopmentRegion`. Every bundle gets [infoPlist]'s, given that
  /// region (from SwiftPM's partial plist when present, else `en`), so the
  /// partial plist never ships.
  ///
  /// Like Xcode, a `.xib` processed by rule (`.process(...)` or a default
  /// rule) ships as the `.nib` [compileXib] makes of it, at the same
  /// relative path; a `.copy(...)` one ships as-is
  /// ([SwiftPmResourceBundle.isCopiedVerbatim], and a copied directory is
  /// always verbatim). SwiftPM itself never compiles a `.xib`, so without a
  /// manifest every `.xib` of the built bundle is compiled. A `.xib` the
  /// compiler cannot reproduce ships unchanged with a warning, and a
  /// `.storyboard` ships uncompiled with a warning.
  Future<List<String>> copyResourceBundles(
    Iterable<SwiftPmResourceBundle> bundles,
    String bundleDir, {
    void Function(String message)? warn,
    String Function(SwiftPmResourceBundle bundle, String developmentRegion)?
    infoPlist,
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
        await _copyGenerated(bundle, destination, null, covered, warn);
        if (resourceBundle.resources == null) {
          await _compileInterfaceFiles(destination, resourceBundle, warn);
        }
      }
      for (final resource in resources) {
        final target = paths.join(destination, resource.relative);
        await _copyFromSource(
          resource.source,
          target,
          bundleRoot: destination,
          warn: warn,
        );
        if (!resourceBundle.isCopiedVerbatim(resource, paths) &&
            fileSystem.file(target).existsSync() &&
            !fileSystem.link(target).existsSync()) {
          await _compileInterfaceFile(target, resourceBundle, warn);
        }
      }
      final plist = fileSystem.file(paths.join(destination, 'Info.plist'));
      if (infoPlist != null) {
        final region = plist.existsSync()
            ? swiftPmDevelopmentRegion(plist.readAsStringSync())
            : null;
        await plist.writeAsString(infoPlist(resourceBundle, region ?? 'en'));
      }
      copied.add(destination);
    }
    return copied;
  }

  /// Compiles every interface file under [directory] (a bundle copied
  /// without a manifest).
  Future<void> _compileInterfaceFiles(
    String directory,
    SwiftPmResourceBundle bundle,
    void Function(String message)? warn,
  ) async {
    final files = <String>[];
    await for (final entity
        in fileSystem.directory(directory).list(followLinks: false)) {
      if (fileSystem.link(entity.path).existsSync()) continue;
      if (fileSystem.directory(entity.path).existsSync()) {
        await _compileInterfaceFiles(entity.path, bundle, warn);
      } else {
        files.add(entity.path);
      }
    }
    for (final file in files) {
      await _compileInterfaceFile(file, bundle, warn);
    }
  }

  /// Replaces the `.xib` at [path] with its `.nib`, as Xcode's
  /// `CompileXIB` does, or leaves it with a warning when it cannot.
  Future<void> _compileInterfaceFile(
    String path,
    SwiftPmResourceBundle bundle,
    void Function(String message)? warn,
  ) async {
    final extension = paths.extension(path).toLowerCase();
    final name = paths.basename(bundle.bundlePath);
    if (extension == '.storyboard') {
      warn?.call(
        'storyboard ${paths.basename(path)} in bundle $name is copied '
        'uncompiled.',
      );
      return;
    }
    if (extension != '.xib') return;
    final file = fileSystem.file(path);
    final XibCompilation result;
    try {
      result = compileXib(
        await file.readAsString(),
        module:
            bundle.moduleName ??
            paths.basenameWithoutExtension(name).split('_').last,
        deploymentTarget: bundle.minimumOsVersion ?? swiftPmOldestIosVersion,
      );
    } on Object catch (error) {
      warn?.call('Copying ${paths.basename(path)} in $name uncompiled: $error');
      return;
    }
    final nib = result.nib;
    if (nib == null) {
      warn?.call(
        'Copying ${paths.basename(path)} in $name uncompiled: '
        '${result.unsupported.join(', ')}.',
      );
      return;
    }
    final output = fileSystem.file(
      paths.join(
        paths.dirname(path),
        '${paths.basenameWithoutExtension(path)}.nib',
      ),
    );
    if (output.existsSync()) await output.delete();
    await output.writeAsBytes(nib);
    await file.delete();
  }

  static const _excluded = {'.DS_Store', 'CVS', '.svn', '.git', '.hg'};

  /// Copies what the built bundle holds outside the [covered] resources.
  /// [prefix] is the bundle-relative path of [directory] (null at the root).
  /// It is built from listed names rather than `paths.relative`, which on
  /// Windows misses when the listing carries the `\\?\` long-path prefix
  /// and the bundle path does not.
  ///
  /// Without a manifest (`covered` empty) the built bundle's `.lproj`
  /// directories keep the lowercase names `swift build` gave them
  /// (`en_gb.lproj` where Xcode ships `en_GB.lproj`): the source casing is
  /// only recoverable from the manifest's `copy-tool` inputs (see
  /// `restoreLprojCasing`).
  Future<void> _copyGenerated(
    String directory,
    String destination,
    String? prefix,
    Set<String> covered,
    void Function(String message)? warn, {
    String? bundle,
  }) async {
    bundle ??= directory;
    await for (final entity
        in fileSystem.directory(directory).list(followLinks: false)) {
      final name = paths.basename(entity.path);
      final relative = prefix == null ? name : paths.join(prefix, name);
      final coverage = resourceCoverage(paths, relative, covered);
      if (coverage == ResourceCoverage.covered) continue;
      final target = paths.join(destination, name);
      if (coverage == ResourceCoverage.holdsResource &&
          !fileSystem.link(entity.path).existsSync() &&
          fileSystem.directory(entity.path).existsSync()) {
        await fileSystem.directory(target).create(recursive: true);
        await _copyGenerated(
          entity.path,
          target,
          relative,
          covered,
          warn,
          bundle: bundle,
        );
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
      await _copyFile(path, destination);
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
        await _copyFile(path, target);
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
      await _copyFile(path, destination);
    }
  }

  /// Copies a file over whatever [destination] holds. `File.copy` replaces
  /// an existing file on POSIX but throws `PathExistsException` on Windows;
  /// a resource copied from source must replace a generated copy (the
  /// source wins, as in Xcode).
  Future<void> _copyFile(String source, String destination) async {
    final existing = fileSystem.file(destination);
    if (fileSystem.link(destination).existsSync()) {
      await fileSystem.link(destination).delete();
    } else if (existing.existsSync()) {
      await existing.delete();
    }
    await fileSystem.file(source).copy(existing.path);
  }
}

/// The shape of [XibCompiler.compile].
@internal
typedef XibCompile =
    XibCompilation Function(
      String xml, {
      required String module,
      required String deploymentTarget,
    });

/// How a bundle-relative path relates to the resources a manifest declares.
@internal
enum ResourceCoverage { covered, holdsResource, none }

/// Classifies the bundle-relative [relative] path against the [covered]
/// resource paths, with [paths]' separator and case rules (Windows compares
/// case-insensitively and accepts both separators). Paths are always
/// compared case-insensitively, because the built bundle's `.lproj`
/// directories are lowercased by `swift build` while [covered] carries the
/// source casing (see `restoreLprojCasing`).
@internal
ResourceCoverage resourceCoverage(
  p.Context paths,
  String relative,
  Iterable<String> covered,
) {
  final folded = relative.toLowerCase();
  if (covered.any((resource) => paths.equals(folded, resource.toLowerCase()))) {
    return ResourceCoverage.covered;
  }
  if (covered.any(
    (resource) => paths.isWithin(folded, resource.toLowerCase()),
  )) {
    return ResourceCoverage.holdsResource;
  }
  return ResourceCoverage.none;
}
