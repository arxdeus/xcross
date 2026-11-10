import 'dart:convert';

import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:crypto/crypto.dart';
import 'package:darwin_sdk_kit/target/shared/ios_build_platform.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/swiftpm/host_package_link.dart';
import 'package:xcross/src/shared/compose/swiftpm/host_packages_manifest.dart';
import 'package:xcross/src/shared/compose/swiftpm/swift_package_model.dart';
import 'package:xcross/src/shared/swiftpm/ios_deployment_target.dart';
import 'package:xcross/src/shared/swiftpm/package_builder.dart';
import 'package:xcross/src/shared/swiftpm/swiftpm_workspace.dart';

/// Lazily provides the shared SwiftPM engine, so projects without Swift
/// packages never construct it.
@internal
typedef ComposeSwiftPmBuilder<T extends PlatformHostInterface> =
    SwiftPmPackageBuilder<T> Function();

/// Builds the Swift packages a SwiftUI host's Xcode project declares as one
/// aggregate dynamic product (`XcrossHostPackages`) through the SwiftPM
/// engine Flutter plugins build with.
@internal
final class HostPackagesBuilder<T extends PlatformHostInterface> {
  HostPackagesBuilder({
    required this.builder,
    required this.files,
    required this.log,
    this.productName = defaultHostPackagesProductName,
  });

  final SwiftPmPackageBuilder<T> builder;
  final HostFileSystemInterface files;
  final Log log;
  final String productName;

  /// Stages the aggregate package for [packages], builds it, and returns how
  /// the host links it. `swift build` is incremental, and the staged files
  /// are only rewritten when their content changes, so an unchanged rebuild
  /// is a no-op build plus assembly.
  Future<HostPackageLink> build({
    required String projectRoot,
    required HostSwiftPackages packages,
    required IosBuildPlatformInterface platform,
    Map<String, String>? environment,
  }) async {
    final deploymentTarget = IosDeploymentTarget(
      hostPackagesDeploymentTarget(packages),
      platform: platform,
    );
    final workspace = builder.workspaceFor(
      projectRoot,
      environment: environment,
    );
    final packageDir = await stage(workspace, packages);
    final debugDir = builder.targetDebugDirectory(workspace, deploymentTarget);
    await pruneStaleHostPackageProducts(
      files: files,
      log: log,
      packageDir: packageDir,
      packages: packages,
      debugDirectory: debugDir,
    );
    final result = await builder.build(
      workspace: workspace,
      packageDir: packageDir,
      productName: productName,
      deploymentTarget: deploymentTarget,
    );
    final debugYaml = files.file(p.join(workspace.scratch, 'debug.yaml'));
    final moduleMaps = debugYaml.existsSync()
        ? swiftPmModuleMapFiles(debugYaml.readAsStringSync())
        : const <String>[];
    return HostPackageLink(
      productName: productName,
      libraryPath: result.libraryPath,
      modulesDir: result.modulesDir,
      moduleMapFiles: moduleMaps,
      frameworkSearchPaths: [debugDir],
      build: result,
      deploymentTarget: deploymentTarget.version,
      modules: swiftPmBuiltModules(
        files: files,
        debugDirectory: debugDir,
        moduleMapFiles: moduleMaps,
      ),
    );
  }

  /// Writes the aggregate package into `<workspace.packages>/<productName>`
  /// (only files whose content changed) with Xcode's `Package.resolved`
  /// beside it, and returns its directory.
  @visibleForTesting
  Future<String> stage(
    SwiftPmWorkspace workspace,
    HostSwiftPackages packages,
  ) async {
    final packageDir = p.join(workspace.packages, productName);
    final manifest = generateHostPackagesManifest(
      packages: packages,
      deploymentTarget: hostPackagesDeploymentTarget(packages),
      productName: productName,
    );
    for (final MapEntry(key: relative, value: content)
        in manifest.allFiles.entries) {
      await _writeIfChanged(
        p.joinAll([packageDir, ...p.posix.split(relative)]),
        content,
      );
    }
    final resolved = packages.packageResolvedPath;
    final staged = p.join(packageDir, 'Package.resolved');
    if (resolved != null && files.file(resolved).existsSync()) {
      await _writeIfChanged(staged, files.file(resolved).readAsStringSync());
    }
    return packageDir;
  }

  Future<void> _writeIfChanged(String path, String content) async {
    final file = files.file(path);
    if (file.existsSync() && file.readAsStringSync() == content) return;
    await files.directory(p.dirname(path)).create(recursive: true);
    await file.writeAsString(content);
  }
}

/// Name of the file in the debug directory recording which package graph
/// its products were built from.
@internal
const hostPackagesGraphFingerprintFile = '.xcross-host-packages-graph';

/// Deletes [debugDirectory] when the package graph changed since the
/// products in it were built.
///
/// SwiftPM never removes the products of targets that left the graph, and
/// assembly collects every `*.bundle` and `*.build` there, so a removed
/// package (or a resource target dropped by a new version or by an edited
/// local `Package.swift`) would otherwise keep shipping its bundle. The
/// graph is the staged aggregate `Package.swift`, the staged
/// `Package.resolved` and every local package's `Package.swift`. When it
/// is unchanged the directory is kept and `swift build` stays incremental.
@internal
Future<void> pruneStaleHostPackageProducts({
  required HostFileSystemInterface files,
  required Log log,
  required String packageDir,
  required HostSwiftPackages packages,
  required String debugDirectory,
}) async {
  final fingerprint = _graphFingerprint(files, packageDir, packages);
  final directory = files.directory(debugDirectory);
  final record = files.file(
    p.join(debugDirectory, hostPackagesGraphFingerprintFile),
  );
  if (record.existsSync() && record.readAsStringSync() == fingerprint) {
    return;
  }
  if (directory.existsSync()) {
    log.logTrace(
      'Swift package graph changed, removing stale SwiftPM products in '
      '$debugDirectory',
    );
    await directory.delete(recursive: true);
  }
  await directory.create(recursive: true);
  await record.writeAsString(fingerprint);
}

String _graphFingerprint(
  HostFileSystemInterface files,
  String packageDir,
  HostSwiftPackages packages,
) {
  final buffer = StringBuffer();
  void add(String label, String path) {
    final file = files.file(path);
    final content = file.existsSync() ? file.readAsStringSync() : '';
    buffer
      ..write(label)
      ..write('\u0000')
      ..write(content.length)
      ..write('\u0000')
      ..write(content)
      ..write('\u0000');
  }

  add('aggregate', p.join(packageDir, 'Package.swift'));
  add('resolved', p.join(packageDir, 'Package.resolved'));
  for (final package in packages.packages) {
    if (package is LocalSwiftPackage) {
      add(package.path, p.join(package.path, 'Package.swift'));
    }
  }
  return sha256.convert(utf8.encode(buffer.toString())).toString();
}
