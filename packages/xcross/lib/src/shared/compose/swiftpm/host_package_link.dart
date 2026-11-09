import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/compose_ios_constants.dart';
import 'package:xcross/src/shared/compose/swiftpm/host_swift_packages_reader.dart';
import 'package:xcross/src/shared/compose/swiftpm/swift_package_model.dart';
import 'package:xcross/src/shared/swiftpm/clang_modules.dart';
import 'package:xcross/src/shared/swiftpm/package_types.dart';

/// What the SwiftUI host needs to compile and link against the Swift
/// packages its Xcode project declares, after `swift build` built them.
@internal
@immutable
final class HostPackageLink {
  const HostPackageLink({
    required this.productName,
    required this.libraryPath,
    required this.modulesDir,
    required this.moduleMapFiles,
    required this.frameworkSearchPaths,
    required this.build,
    this.modules = const {},
    this.deploymentTarget = composeMinimumIosVersion,
  });

  /// The iOS version the packages were built for: the app target's
  /// `IPHONEOS_DEPLOYMENT_TARGET` when higher than the Compose minimum, as
  /// Xcode builds them. swiftc refuses to import a module built for a newer
  /// iOS than the importer, so the host and the app follow it.
  final String deploymentTarget;

  /// The aggregate dynamic product (`XcrossHostPackages`).
  final String productName;

  /// The aggregate dylib, already carrying the install name
  /// `@rpath/<productName>.framework/<productName>`.
  final String libraryPath;

  /// SwiftPM's `Modules` directory (`*.swiftmodule`), or null.
  final String? modulesDir;

  /// Every module map SwiftPM passed as `-fmodule-map-file=`: Swift modules
  /// that wrap C targets (e.g. `RealModule` over `_NumericsShims`) need them
  /// to load, even when the host never imports the C module itself.
  final List<String> moduleMapFiles;

  /// Where binary-target frameworks were copied (SwiftPM's debug directory).
  final List<String> frameworkSearchPaths;

  /// The full build result, for embedding the products in the app.
  final SwiftPmBuildResult build;

  /// Every module the build made importable.
  final Set<String> modules;

  /// The extra `swiftc` arguments that compile and link the host against
  /// the packages.
  List<String> get swiftcArguments => [
    if (modulesDir != null) ...['-I', modulesDir!],
    for (final map in moduleMapFiles) ...['-Xcc', '-fmodule-map-file=$map'],
    for (final dir in frameworkSearchPaths) ...['-F', dir],
    '-Xlinker',
    libraryPath,
  ];
}

/// The iOS version Xcode would build [declared] for: the app targets'
/// deployment target, never below the Compose minimum.
@internal
String hostPackagesDeploymentTarget(HostSwiftPackages declared) {
  final declaredTarget = declared.deploymentTarget;
  return declaredTarget != null &&
          compareVersions(declaredTarget, composeMinimumIosVersion) > 0
      ? declaredTarget
      : composeMinimumIosVersion;
}

/// Absolute module map paths passed as `-fmodule-map-file=` in SwiftPM's
/// build manifest ([debugYaml] is the text of `<scratch>/debug.yaml`),
/// unique, in first-seen order.
@internal
List<String> swiftPmModuleMapFiles(String debugYaml) {
  final found = <String>{};
  for (final match in RegExp(
    r'-fmodule-map-file=((?:[^"\\\s]|\\.)+)',
  ).allMatches(debugYaml)) {
    found.add(match.group(1)!.replaceAll(r'\\', r'\'));
  }
  return found.toList();
}

/// The modules a SwiftPM build in [debugDirectory] makes importable:
/// `Modules/*.swiftmodule`, binary frameworks `*.framework` in the debug
/// directory, and the top-level modules of [moduleMapFiles].
@internal
Set<String> swiftPmBuiltModules({
  required HostFileSystemInterface files,
  required String debugDirectory,
  required List<String> moduleMapFiles,
}) {
  final modules = <String>{};
  Iterable<FileSystemEntity> list(String dir) {
    final directory = files.directory(dir);
    if (!directory.existsSync()) return const [];
    try {
      return directory.listSync(followLinks: false);
    } on FileSystemException {
      return const [];
    }
  }

  for (final entry in list(p.join(debugDirectory, 'Modules'))) {
    final name = p.basename(entry.path);
    if (name.endsWith('.swiftmodule')) {
      modules.add(p.basenameWithoutExtension(name));
    }
  }
  for (final entry in list(debugDirectory)) {
    final name = p.basename(entry.path);
    if (entry is Directory && name.endsWith('.framework')) {
      modules.add(p.basenameWithoutExtension(name));
    }
  }
  for (final map in moduleMapFiles) {
    final file = files.file(map);
    if (!file.existsSync()) continue;
    try {
      modules.addAll(
        SwiftPmClangModules.topLevelModuleNames(file.readAsStringSync()),
      );
    } on FileSystemException {
      continue;
    }
  }
  return modules;
}

/// Modules the [declared] packages can be told to provide without the
/// network: their product names, the targets of local packages, and the
/// targets of packages an earlier build already checked out into
/// [checkoutsDir]. A superset (test targets included) is fine here: the
/// exact check runs against the built modules.
@internal
Set<String> declaredPackageModules(
  HostSwiftPackages declared,
  HostFileSystemInterface files, {
  String? checkoutsDir,
}) {
  final modules = {
    for (final product in declared.products) product.productName,
  };
  void readManifest(String packageDir) {
    final manifest = files.file(p.join(packageDir, 'Package.swift'));
    if (!manifest.existsSync()) return;
    try {
      modules.addAll(declaredPackageTargets(manifest.readAsStringSync()));
    } on FileSystemException {
      return;
    }
  }

  for (final package in declared.packages) {
    if (package is LocalSwiftPackage) readManifest(package.path);
  }
  if (checkoutsDir != null) {
    final dir = files.directory(checkoutsDir);
    if (dir.existsSync()) {
      try {
        for (final entry in dir.listSync(followLinks: false)) {
          if (entry is Directory) readManifest(entry.path);
        }
      } on FileSystemException {
        // Unreadable checkouts only make the preflight less precise.
      }
    }
  }
  return modules;
}

/// Target names declared by `.target(name:)`-style calls in a
/// `Package.swift`, a cheap superset of the modules a package can provide.
@internal
Set<String> declaredPackageTargets(String manifest) => {
  for (final m in RegExp(
    r'\.(?:target|binaryTarget|systemLibrary)\s*\(\s*name\s*:\s*"((?:[^"\\]|\\.)*)"',
  ).allMatches(manifest))
    m.group(1)!,
};
