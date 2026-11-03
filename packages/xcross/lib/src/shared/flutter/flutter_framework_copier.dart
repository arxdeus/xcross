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
      final destination = paths.join(
        bundleDir,
        paths.basename(resourceBundle.bundlePath),
      );
      if (fileSystem.directory(destination).existsSync()) continue;
      final plan = planResourceBundle(resourceBundle, warn: warn);
      await fileSystem.directory(destination).create(recursive: true);
      await _execute(
        plan,
        destination,
        resourceBundle,
        warn,
        skipInfoPlist: infoPlist != null,
      );
      if (infoPlist != null) {
        final generated = plan['Info.plist'];
        final region = generated is BundleFile
            ? swiftPmDevelopmentRegion(
                fileSystem.file(generated.source).readAsStringSync(),
              )
            : null;
        await fileSystem
            .file(paths.join(destination, 'Info.plist'))
            .writeAsString(infoPlist(resourceBundle, region ?? 'en'));
      }
      copied.add(destination);
    }
    return copied;
  }

  /// The contents of [bundle] as [copyResourceBundles] writes them: every
  /// bundle-relative destination mapped to what is written there, each
  /// exactly once.
  ///
  /// It holds the files of the built bundle no declared resource covers
  /// (all of it without a manifest), then every declared resource expanded
  /// from its source; a resource replaces an earlier entry at the same path,
  /// compared case-insensitively. Directories take the source casing
  /// (`en_GB.lproj`, where `swift build` writes `en_gb.lproj`), so a built
  /// file under a resource directory lands in the source-cased one.
  /// Iteration order puts every directory before its contents.
  Map<String, BundleEntry> planResourceBundle(
    SwiftPmResourceBundle bundle, {
    void Function(String message)? warn,
  }) {
    final plan = BundlePlan(paths);
    final name = paths.basename(bundle.bundlePath);
    final resources = bundle.resources;
    if (fileSystem.directory(bundle.bundlePath).existsSync()) {
      _planGenerated(
        bundle.bundlePath,
        null,
        {
          for (final resource in resources ?? const <SwiftPmBundleResource>[])
            paths.normalize(resource.relative),
        },
        plan,
        name: name,
        compile: resources == null,
        warn: warn,
      );
    }
    for (final resource in resources ?? const <SwiftPmBundleResource>[]) {
      _expand(
        resource.source,
        paths.normalize(resource.relative),
        plan,
        name: name,
        fromSource: true,
        compile: !bundle.isCopiedVerbatim(resource, paths),
        warn: warn,
        topLevel: true,
        linkRoot: '',
      );
    }
    return plan.build();
  }

  /// Plans what the built bundle holds outside the [covered] resources.
  /// [prefix] is the bundle-relative path of [directory] (null at the root).
  /// It is built from listed names rather than `paths.relative`, which on
  /// Windows misses when the listing carries the `\\?\` long-path prefix
  /// and the bundle path does not. A directory that only holds declared
  /// resources is not planned itself: their source copies give it the
  /// source casing.
  void _planGenerated(
    String directory,
    String? prefix,
    Set<String> covered,
    BundlePlan plan, {
    required String name,
    required bool compile,
    required void Function(String message)? warn,
  }) {
    for (final entity in _list(directory)) {
      final entry = paths.basename(entity);
      final relative = prefix == null ? entry : paths.join(prefix, entry);
      final coverage = resourceCoverage(paths, relative, covered);
      if (coverage == ResourceCoverage.covered) continue;
      if (coverage == ResourceCoverage.holdsResource &&
          !fileSystem.link(entity).existsSync() &&
          fileSystem.directory(entity).existsSync()) {
        _planGenerated(
          entity,
          relative,
          covered,
          plan,
          name: name,
          compile: compile,
          warn: warn,
        );
        continue;
      }
      _expand(
        entity,
        relative,
        plan,
        name: name,
        fromSource: false,
        compile: compile,
        warn: warn,
        topLevel: true,
        linkRoot: '',
      );
    }
  }

  static const _excluded = {'.DS_Store', 'CVS', '.svn', '.git', '.hg'};

  /// Plans [path] at the bundle-relative [relative], the one link resolver
  /// for sources and the built bundle alike.
  ///
  /// A [topLevel] link (a resource, or an entry of the built bundle) is
  /// copied as its target, as Xcode's `builtin-copy -resolve-src-symlinks`
  /// does. A link inside a copied directory stays a link when its relative
  /// target stays within [linkRoot] (bundle-relative, `''` for the whole
  /// bundle) and, for a source, resolves there; any other link is copied as
  /// its target, because codesign and installd reject dangling links, and is
  /// skipped with a warning when that target does not exist.
  void _expand(
    String path,
    String relative,
    BundlePlan plan, {
    required String name,
    required bool fromSource,
    required bool compile,
    required void Function(String message)? warn,
    required bool topLevel,
    required String linkRoot,
    Set<String>? visited,
  }) {
    var resolved = path;
    final link = fileSystem.link(path);
    if (link.existsSync()) {
      final target = link.targetSync();
      if (!topLevel &&
          !paths.isAbsolute(target) &&
          _staysWithin(linkRoot, paths.join(paths.dirname(relative), target)) &&
          (!fromSource || _exists(path))) {
        plan.add(relative, BundleLink(target, path), fromSource: fromSource);
        return;
      }
      try {
        resolved = fileSystem.file(path).resolveSymbolicLinksSync();
      } on FileSystemException {
        warn?.call(
          'Skipping ${paths.basename(path)} in $name: it links to '
          '$target, which does not exist.',
        );
        return;
      }
    }
    if (fileSystem.directory(resolved).existsSync()) {
      visited ??= <String>{};
      // A link cycle (a directory linking to an ancestor) would never end.
      final canonical = fileSystem
          .directory(resolved)
          .resolveSymbolicLinksSync();
      if (!visited.add(canonical)) {
        warn?.call(
          'Skipping ${paths.basename(path)} in $name: its links '
          'form a cycle.',
        );
        return;
      }
      plan.add(relative, const BundleDirectory(), fromSource: fromSource);
      for (final child in _list(resolved)) {
        final entry = paths.basename(child);
        if (fromSource && _excluded.contains(entry)) continue;
        _expand(
          child,
          paths.join(relative, entry),
          plan,
          name: name,
          fromSource: fromSource,
          // A resource directory is copied verbatim; a built bundle is
          // compiled throughout when there is no manifest.
          compile: compile && !fromSource,
          warn: warn,
          topLevel: false,
          // A built directory reached through a link is copied as-is, so
          // links inside it are judged against that directory.
          linkRoot: !fromSource && resolved != path ? relative : linkRoot,
          visited: visited,
        );
      }
      visited.remove(canonical);
    } else if (fileSystem.file(resolved).existsSync()) {
      plan.add(
        relative,
        BundleFile(resolved, compile: compile),
        fromSource: fromSource,
      );
    } else if (fromSource && topLevel) {
      warn?.call(
        'Skipping ${paths.basename(path)} in $name: $path does '
        'not exist.',
      );
    }
  }

  bool _staysWithin(String root, String relative) {
    const anchor = 'bundle';
    return paths.isWithin(
      paths.normalize(paths.join(anchor, root)),
      paths.normalize(paths.join(anchor, relative)),
    );
  }

  bool _exists(String path) =>
      fileSystem.file(path).existsSync() ||
      fileSystem.directory(path).existsSync();

  List<String> _list(String directory) => [
    for (final entity
        in fileSystem.directory(directory).listSync(followLinks: false))
      entity.path,
  ]..sort();

  /// Writes every [plan] entry under [destination], once each.
  Future<void> _execute(
    Map<String, BundleEntry> plan,
    String destination,
    SwiftPmResourceBundle bundle,
    void Function(String message)? warn, {
    required bool skipInfoPlist,
  }) async {
    for (final MapEntry(key: relative, value: entry) in plan.entries) {
      final target = paths.join(destination, relative);
      if (entry is! BundleDirectory &&
          (fileSystem.link(target).existsSync() ||
              fileSystem.file(target).existsSync())) {
        // The plan maps each path once; reaching an existing entry means a
        // case collision slipped through, which a copy would silently hide.
        throw StateError('$target is planned twice.');
      }
      switch (entry) {
        case BundleDirectory():
          await fileSystem.directory(target).create(recursive: true);
        case BundleFile(:final source, :final compile):
          if (skipInfoPlist && relative == 'Info.plist') continue;
          await fileSystem
              .directory(paths.dirname(target))
              .create(recursive: true);
          if (compile) {
            await _compileInterfaceFile(source, target, bundle, warn);
          } else {
            await fileSystem.file(source).copy(fileSystem.file(target).path);
          }
        case BundleLink(target: final linkTarget, :final source):
          await fileSystem
              .directory(paths.dirname(target))
              .create(recursive: true);
          try {
            await fileSystem.link(target).create(linkTarget);
          } on FileSystemException {
            // No symlink rights (Windows): copy what it points at instead,
            // which keeps the content identical.
            final fallback = BundlePlan(paths);
            _expand(
              source,
              paths.basename(target),
              fallback,
              name: paths.basename(destination),
              fromSource: false,
              compile: false,
              warn: warn,
              topLevel: true,
              linkRoot: '',
            );
            await _execute(
              fallback.build(),
              paths.dirname(target),
              bundle,
              warn,
              skipInfoPlist: false,
            );
          }
      }
    }
  }

  /// Writes the `.nib` of the `.xib` at [source] next to [target], as
  /// Xcode's `CompileXIB` does, or copies it there with a warning when it
  /// cannot.
  Future<void> _compileInterfaceFile(
    String source,
    String target,
    SwiftPmResourceBundle bundle,
    void Function(String message)? warn,
  ) async {
    Future<void> copy() =>
        fileSystem.file(source).copy(fileSystem.file(target).path);
    final extension = paths.extension(target).toLowerCase();
    final name = paths.basename(bundle.bundlePath);
    if (extension == '.storyboard') {
      warn?.call(
        'storyboard ${paths.basename(target)} in bundle $name is copied '
        'uncompiled.',
      );
      await copy();
      return;
    }
    if (extension != '.xib') {
      await copy();
      return;
    }
    final XibCompilation result;
    try {
      result = compileXib(
        await fileSystem.file(source).readAsString(),
        module:
            bundle.moduleName ??
            paths.basenameWithoutExtension(name).split('_').last,
        deploymentTarget: bundle.minimumOsVersion ?? swiftPmOldestIosVersion,
      );
    } on Object catch (error) {
      warn?.call(
        'Copying ${paths.basename(target)} in $name uncompiled: $error',
      );
      await copy();
      return;
    }
    final nib = result.nib;
    if (nib == null) {
      warn?.call(
        'Copying ${paths.basename(target)} in $name uncompiled: '
        '${result.unsupported.join(', ')}.',
      );
      await copy();
      return;
    }
    await fileSystem
        .file(
          paths.join(
            paths.dirname(target),
            '${paths.basenameWithoutExtension(target)}.nib',
          ),
        )
        .writeAsBytes(nib);
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

/// What [FlutterFrameworkCopier.planResourceBundle] writes at one
/// bundle-relative path.
@internal
@immutable
sealed class BundleEntry {
  const BundleEntry();
}

/// A directory.
@internal
final class BundleDirectory extends BundleEntry {
  const BundleDirectory();

  @override
  bool operator ==(Object other) => other is BundleDirectory;

  @override
  int get hashCode => (BundleDirectory).hashCode;

  @override
  String toString() => 'BundleDirectory()';
}

/// A copy of [source], or, when [compile] is set and it is an interface
/// file, what Xcode compiles it into.
@internal
final class BundleFile extends BundleEntry {
  const BundleFile(this.source, {this.compile = false});

  final String source;
  final bool compile;

  @override
  bool operator ==(Object other) =>
      other is BundleFile && other.source == source && other.compile == compile;

  @override
  int get hashCode => Object.hash(source, compile);

  @override
  String toString() => 'BundleFile($source, compile: $compile)';
}

/// A link to the relative [target], made from the link at [source] (whose
/// target is copied instead where links cannot be created).
@internal
final class BundleLink extends BundleEntry {
  const BundleLink(this.target, this.source);

  final String target;
  final String source;

  @override
  bool operator ==(Object other) =>
      other is BundleLink && other.target == target && other.source == source;

  @override
  int get hashCode => Object.hash(target, source);

  @override
  String toString() => 'BundleLink($target, $source)';
}

/// Collects the entries of a bundle plan, keyed case-insensitively.
@internal
final class BundlePlan {
  BundlePlan(this.paths);

  final p.Context paths;
  final _entries = <String, (String, BundleEntry, bool)>{};

  /// Plans [entry] at [relative], replacing what an earlier entry planned
  /// at the same path in any casing.
  void add(String relative, BundleEntry entry, {required bool fromSource}) {
    final key = _fold(relative);
    _entries.remove(key);
    _entries[key] = (relative, entry, fromSource);
  }

  String _fold(String relative) =>
      paths.split(paths.normalize(relative)).join('/').toLowerCase();

  /// The planned entries, every directory before its contents and every
  /// path in one casing: a directory takes the casing a source entry gave
  /// it (`en_GB.lproj`), else the first one planned.
  Map<String, BundleEntry> build() {
    final casing = <String, String>{};
    for (final pass in [true, false]) {
      for (final (relative, _, fromSource) in _entries.values) {
        if (fromSource != pass) continue;
        final parts = paths.split(paths.normalize(relative));
        for (var i = 1; i <= parts.length; i++) {
          casing.putIfAbsent(
            parts.take(i).join('/').toLowerCase(),
            () => parts[i - 1],
          );
        }
      }
    }
    String cased(String key) {
      final parts = key.split('/');
      return paths.joinAll([
        for (var i = 1; i <= parts.length; i++)
          casing[parts.take(i).join('/')]!,
      ]);
    }

    final keys = {
      for (final key in _entries.keys) ...[
        for (var i = key.indexOf('/'); i != -1; i = key.indexOf('/', i + 1))
          key.substring(0, i),
        key,
      ],
    }.toList()..sort((a, b) => _compare(a.split('/'), b.split('/')));
    return {
      for (final key in keys)
        cased(key): _entries[key]?.$2 ?? const BundleDirectory(),
    };
  }

  static int _compare(List<String> a, List<String> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      final order = a[i].compareTo(b[i]);
      if (order != 0) return order;
    }
    return a.length.compareTo(b.length);
  }
}
