import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/apple/mach_o.dart';
import 'package:xcross/src/shared/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/shared/flutter/build/macho_dylib_rewriter.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dynamic_product.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_build_services.dart';
import 'package:xcross/src/shared/flutter/swiftpm/resource_manifest.dart';

@internal
const String flutterFrameworkPackageName = 'FlutterFramework';
@internal
const String pluginsProductName = 'FlutterPluginsGenerated';

@internal
final class SwiftPmAssembly<T extends PlatformHostInterface> {
  SwiftPmAssembly({required this.hostBuildServices, required this.fileSystem});

  final SwiftPmHostBuildServices<T> hostBuildServices;
  final SwiftPmArtifactFileSystem fileSystem;

  /// Finds and fixes every dylib emitted into SwiftPM's target debug output.
  ///
  /// [pluginIdentities] maps the SwiftPM identity xcross stages a Flutter
  /// plugin package under (its lowercased name) to the one Xcode gives it
  /// (see [flutterPluginSwiftPmIdentities]), for resource bundle identifiers.
  Future<GeneratedPluginsBuildResult> discoverAndRewriteDylibs(
    String targetDebugDir, {
    Map<String, String> pluginIdentities = const {},
  }) async {
    final dylibPaths = <String>[];
    await for (final entity in fileSystem.directory(targetDebugDir).list()) {
      if (entity is File && p.extension(entity.path) == '.dylib') {
        dylibPaths.add(p.absolute(fileSystem.processPath(entity.path)));
      }
    }
    dylibPaths.sort();

    const aggregateName = 'lib$pluginsProductName.dylib';
    final aggregatePath = dylibPaths
        .where((path) => p.basename(path) == aggregateName)
        .firstOrNull;
    if (aggregatePath == null) {
      throw FlutterBuildError(
        'GeneratedPluginsPackage: swift build did not produce the plugins '
        'library in $targetDebugDir',
      );
    }

    final dylibNames = dylibPaths.map(p.basename).toSet();
    for (final path in dylibPaths) {
      await hostBuildServices.rewriteDylib(path, dylibNames);
    }
    final productInstallNames = {
      for (final name in dylibNames)
        name: swiftPmDynamicProductInstallName(swiftPmDynamicProductName(name)),
    };
    for (final path in dylibPaths) {
      await _adoptFrameworkInstallName(path, productInstallNames);
    }
    // SwiftPM emits .swiftmodule files into a sibling `Modules` directory;
    // app-extension targets importing a plugin need it on their include path.
    final modulesPath = p.join(targetDebugDir, 'Modules');
    final frameworkPaths = <String>[];
    final resourceBundlePaths = <String>[];
    await for (final entity in fileSystem.directory(targetDebugDir).list()) {
      if (entity is Directory && p.extension(entity.path) == '.bundle') {
        resourceBundlePaths.add(
          p.absolute(fileSystem.processPath(entity.path)),
        );
        continue;
      }
      if (entity is! Directory || p.extension(entity.path) != '.framework') {
        continue;
      }
      final binary = fileSystem.file(
        p.join(entity.path, p.basenameWithoutExtension(entity.path)),
      );
      if (binary.existsSync() && isDynamicLibrary(await binary.readAsBytes())) {
        frameworkPaths.add(p.absolute(fileSystem.processPath(entity.path)));
      }
    }
    frameworkPaths.sort();
    resourceBundlePaths.sort();
    // `<scratch>/<triple>/debug`: SwiftPM's build manifest names the source
    // of every resource it copied into a bundle.
    final manifest = fileSystem.file(
      p.join(p.dirname(p.dirname(targetDebugDir)), 'debug.yaml'),
    );
    var copies = const <String, List<SwiftPmBundleResource>>{};
    var versions = const <String, String>{};
    var linkCommands = const <String, Set<String>>{};
    if (manifest.existsSync()) {
      try {
        final text = await manifest.readAsString();
        copies = parseSwiftPmResourceCopies(text, p.context);
        versions = parseSwiftPmTargetDeploymentVersions(text);
        linkCommands = parseSwiftPmLinkedTargets(text, p.context);
      } on FileSystemException {
        // Unreadable: fall back to copying the built bundles as they are.
      }
    }
    final scratchPath = p.dirname(p.dirname(targetDebugDir));
    final state = fileSystem.file(p.join(scratchPath, 'workspace-state.json'));
    var locations = const <String, String>{};
    var packages = const <SwiftPmPackageReference>[];
    if (state.existsSync()) {
      try {
        final text = await state.readAsString();
        locations = parseSwiftPmPackageLocations(text, scratchPath, p.context);
        packages = parseSwiftPmPackageReferences(text, scratchPath, p.context);
      } on FileSystemException {
        // Unreadable: bundle identifiers fall back to the package name.
      }
    }
    final targets = <String>[];
    await for (final entity in fileSystem.directory(targetDebugDir).list()) {
      if (entity is Directory && p.extension(entity.path) == '.build') {
        targets.add(p.basenameWithoutExtension(entity.path));
      }
    }
    // A bundle whose every `copy-tool` output is a dangling link (SDWebImage
    // copies a git symlink pointing outside its target) is never recreated
    // once the products directory is wiped: llbuild recorded the dangling
    // output as missing, so a missing output looks up to date. Its resources
    // are copied from source anyway, as Xcode does, so a manifest bundle of
    // a target linked into a binary this build left (and the app embeds) is
    // kept without a directory.
    final linked = {
      for (final MapEntry(key: binary, value: targets) in linkCommands.entries)
        if (fileSystem.file(binary).existsSync()) ...targets,
    };
    final listed = {for (final path in resourceBundlePaths) p.basename(path)};
    for (final name in missingSwiftPmResourceBundles(
      copies,
      listed,
      targets,
      linked,
    )) {
      resourceBundlePaths.add(
        p.absolute(fileSystem.processPath(p.join(targetDebugDir, name))),
      );
    }
    resourceBundlePaths.sort();
    final packageMinimums = <String, String?>{};
    String? packageMinimum(SwiftPmPackageReference package) =>
        packageMinimums.putIfAbsent(package.directory, () {
          final manifest = fileSystem.file(
            p.join(package.directory, 'Package.swift'),
          );
          try {
            return manifest.existsSync()
                ? swiftPmPackageMinimumOsVersion(manifest.readAsStringSync())
                : null;
          } on FileSystemException {
            return null;
          }
        });
    final packageCopyRules = <String, List<String>?>{};
    List<String>? copyRules(SwiftPmPackageReference package, String target) =>
        packageCopyRules.putIfAbsent('${package.directory}\u0000$target', () {
          final manifest = fileSystem.file(
            p.join(package.directory, 'Package.swift'),
          );
          try {
            return manifest.existsSync()
                ? swiftPmTargetCopyRules(manifest.readAsStringSync(), target)
                : null;
          } on FileSystemException {
            return null;
          }
        });
    SwiftPmResourceBundle describe(String path) {
      final name = p.basename(path);
      final resources = copies[name];
      final declared = packageOfBundle(name, packages);
      final target = declared?.target ?? targetOfBundle(name, targets);
      final stem = p.basenameWithoutExtension(name);
      final source = resources?.firstOrNull?.source;
      final identity =
          declared?.package.identity ??
          (source == null
              ? null
              : packageIdentityOf(source, locations, p.context)) ??
          (target == null
                  ? null
                  : stem.substring(0, stem.length - target.length - 1))
              ?.toLowerCase();
      return SwiftPmResourceBundle(
        bundlePath: path,
        resources: resources,
        packageIdentity: pluginIdentities[identity] ?? identity,
        targetName: target,
        minimumOsVersion:
            (declared == null ? null : packageMinimum(declared.package)) ??
            (target == null ? null : versions[target]),
        copyRules: declared == null || target == null
            ? null
            : copyRules(declared.package, target),
      );
    }

    SwiftPmDynamicProduct product(String path) {
      final name = swiftPmDynamicProductName(p.basename(path));
      for (final package in packages) {
        final manifest = fileSystem.file(
          p.join(package.directory, 'Package.swift'),
        );
        try {
          if (!manifest.existsSync() ||
              !swiftPmDeclaresDynamicLibrary(
                manifest.readAsStringSync(),
                name,
              )) {
            continue;
          }
        } on FileSystemException {
          continue;
        }
        return SwiftPmDynamicProduct(
          libraryPath: path,
          packageIdentity:
              pluginIdentities[package.identity] ?? package.identity,
          minimumOsVersion: packageMinimum(package),
        );
      }
      return SwiftPmDynamicProduct(libraryPath: path, packageIdentity: null);
    }

    return GeneratedPluginsBuildResult(
      libraryPath: aggregatePath,
      dylibPaths: List.unmodifiable(dylibPaths),
      dynamicProducts: List.unmodifiable(dylibPaths.map(product)),
      frameworkPaths: List.unmodifiable(frameworkPaths),
      resourceBundlePaths: List.unmodifiable(resourceBundlePaths),
      resourceBundles: List.unmodifiable([
        for (final path in resourceBundlePaths) describe(path),
      ]),
      modulesDir: fileSystem.directory(modulesPath).existsSync()
          ? p.absolute(modulesPath)
          : null,
    );
  }

  /// Gives the dylib at [path] the install name of the framework the app
  /// embeds it as (see [SwiftPmDynamicProduct]), and points its
  /// dependencies on the other products at their frameworks too. Runs
  /// before Runner and app extensions link it, so their load commands name
  /// the framework, and before anything is signed. Idempotent, so a reused
  /// build passes through it again unchanged.
  Future<void> _adoptFrameworkInstallName(
    String path,
    Map<String, String> productInstallNames,
  ) async {
    final file = fileSystem.file(path);
    final bytes = await file.readAsBytes();
    if (MachODylibRewriter.rewriteBytes(
      bytes,
      dylibName: p.basename(path),
      producedDylibNames: const {},
      installName: productInstallNames[p.basename(path)],
      producedInstallNames: productInstallNames,
      replaceRelocatableId: true,
      source: path,
    )) {
      await file.writeAsBytes(bytes, flush: true);
    }
  }

  static bool isDynamicLibrary(Uint8List bytes) {
    if (bytes.length < MachOConstants.headerSize64) return false;
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0, Endian.little) == MachOConstants.magic64) {
      return data.getUint32(12, Endian.little) == MachOConstants.mhDylib;
    }
    if (data.getUint32(0) != _fatMagic) return false;
    final count = data.getUint32(4);
    for (var index = 0; index < count; index++) {
      final entry = 8 + index * 20;
      if (entry + 20 > bytes.length) return false;
      final offset = data.getUint32(entry + 8);
      if (offset + MachOConstants.headerSize64 > bytes.length) continue;
      if (data.getUint32(offset, Endian.little) == MachOConstants.magic64 &&
          data.getUint32(offset + 12, Endian.little) ==
              MachOConstants.mhDylib) {
        return true;
      }
    }
    return false;
  }

  static const _fatMagic = 0xcafebabe;
}
