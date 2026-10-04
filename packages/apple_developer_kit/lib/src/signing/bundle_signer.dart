import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/src/shared/signing/bundle_inspector.dart';
import 'package:apple_developer_kit/src/shared/signing/bundle_tree.dart';
import 'package:apple_developer_kit/src/signing/bundle_paths.dart';
import 'package:apple_developer_kit/src/signing/bytes.dart';
import 'package:apple_developer_kit/src/signing/code_resources.dart';
import 'package:apple_developer_kit/src/signing/internal/bundle_plan.dart';
import 'package:apple_developer_kit/src/signing/internal/resolved_bundle.dart';
import 'package:apple_developer_kit/src/signing/macho_signer.dart';
import 'package:apple_developer_kit/src/signing/signing_asset.dart';
import 'package:cli_kit/cli_kit_shared.dart' show HostFileSystemInspection;

class BundleSigner {
  /// [asset] signs the app itself. [extensionAssets] maps an embedded
  /// extension's `CFBundleIdentifier` to the signing material provisioned for
  /// it; each app extension needs its own App ID, profile and entitlements,
  /// so it cannot be signed with the host app's asset.
  BundleSigner(
    this.asset, {
    required AppleHostServices hostServices,
    Map<String, SigningAsset> extensionAssets = const {},
  }) : hostServices = hostServices,
       _machoSigner = MachOSigner(asset, hostServices: hostServices),
       _extensionAssets = Map.unmodifiable(extensionAssets),
       _inspector = BundleInspector(
         asset: asset,
         hostServices: hostServices,
         tree: BundleTree(hostServices: hostServices),
       );

  final BundleInspector _inspector;

  final AppleHostServices hostServices;
  final SigningAsset asset;
  final MachOSigner _machoSigner;
  final Map<String, SigningAsset> _extensionAssets;

  /// Validates the whole bundle without changing it.
  Future<void> preflight(String appPath) async {
    await _inspect(appPath);
  }

  Future<BundlePlan> _inspect(String appPath) async {
    final plan = await _inspector.inspect(appPath);
    for (final bundle in plan.bundles.where(
      (bundle) => bundle.isAppExtension,
    )) {
      final extensionAsset = _assetFor(bundle);
      BundleInspector.checkApplicationIdentifier(
        extensionAsset,
        bundle.identifier,
        bundle.path,
      );
      if (extensionAsset.teamIdentifier != asset.teamIdentifier) {
        throw AppleError(
          'App extension "${bundle.relativePath}" has a different signing team from its host app.',
        );
      }
    }
    return plan;
  }

  /// Signs nested frameworks and dylibs before sealing and signing the app.
  Future<void> signApp(String appPath, {DateTime? signingTime}) async {
    final plan = await _inspect(appPath);

    for (final bundle in plan.bundles) {
      await _removeIfPresent(
        hostServices.host.paths.context.join(bundle.path, '_CodeSignature'),
      );
      if (!bundle.isRoot) {
        await _removeIfPresent(
          hostServices.host.paths.context.join(
            bundle.path,
            'embedded.mobileprovision',
          ),
        );
      }
    }
    await _atomicWrite(
      hostServices.host.paths.context.join(
        plan.root.path,
        'embedded.mobileprovision',
      ),
      asset.profileCmsBytes,
      plan.root.path,
    );
    // Each extension is its own signed, provisioned bundle.
    for (final extension in plan.bundles.where((b) => b.isAppExtension)) {
      await _atomicWrite(
        hostServices.host.paths.context.join(
          extension.path,
          'embedded.mobileprovision',
        ),
        _assetFor(extension).profileCmsBytes,
        plan.root.path,
      );
    }

    // A bundle seals its children's signatures into its own CodeResources, so
    // the deepest nested code must be finished before its parent is sealed.
    for (final nested in _deepestFirst(plan)) {
      final resources = _codeResources(plan, nested);
      await _writeCodeResources(plan, nested, resources);
      final nestedAsset = _assetFor(nested);
      await MachOSigner(nestedAsset, hostServices: hostServices).signFile(
        nested.executablePath,
        identifier: nested.identifier,
        teamIdentifier: nestedAsset.teamIdentifier,
        // A framework inherits the host's sandbox and needs no entitlements;
        // an app extension is entitled in its own right.
        entitlements: nested.isAppExtension
            ? nestedAsset.entitlements
            : const {},
        infoPlistBytes: nested.infoPlistBytes,
        codeResourcesBytes: resources,
        signingTime: signingTime,
      );
    }

    for (final dylib in plan.looseBinaries) {
      await _machoSigner.signFile(
        dylib.path,
        identifier: dylib.identifier,
        teamIdentifier: asset.teamIdentifier,
        entitlements: const {},
        signingTime: signingTime,
      );
    }

    final rootResources = _codeResources(plan, plan.root);
    await _writeCodeResources(plan, plan.root, rootResources);
    await _machoSigner.signFile(
      plan.root.executablePath,
      identifier: plan.root.identifier,
      teamIdentifier: asset.teamIdentifier,
      entitlements: asset.entitlements,
      infoPlistBytes: plan.root.infoPlistBytes,
      codeResourcesBytes: rootResources,
      signingTime: signingTime,
    );
  }

  /// The signing material for [bundle]: its own provisioned asset when it is
  /// an app extension, otherwise the app's.
  SigningAsset _assetFor(ResolvedBundle bundle) {
    if (!bundle.isAppExtension) return asset;
    final extensionAsset = _extensionAssets[bundle.identifier];
    if (extensionAsset == null) {
      throw AppleError(
        'App extension "${bundle.relativePath}" (${bundle.identifier}) has no '
        "provisioning profile; it cannot be signed with the app's.",
      );
    }
    return extensionAsset;
  }

  static List<ResolvedBundle> _deepestFirst(BundlePlan plan) =>
      plan.bundles.where((bundle) => !bundle.isRoot).toList()
        ..sort((left, right) {
          final depth = _depth(
            right.relativePath,
          ).compareTo(_depth(left.relativePath));
          return depth != 0
              ? depth
              : compareUtf8(left.relativePath, right.relativePath);
        });

  Uint8List _codeResources(BundlePlan plan, ResolvedBundle bundle) {
    final entries = _inspector.tree.readEntries(
      bundle.path,
      _inspector.tree.resolveDirectory(plan.root.path, plan.root.path),
    );
    return CodeResourcesBuilder(hostServices: hostServices).build(
      candidates: [
        for (final entry in entries)
          if (entry.type == FileSystemEntityType.file ||
              entry.type == FileSystemEntityType.link)
            SealCandidate(
              path: entry.path,
              relativePath: entry.relativePath,
              isSymlink: entry.type == FileSystemEntityType.link,
            ),
      ],
      executableRelativePath: bundleRelativePath(
        bundle.path,
        bundle.executablePath,
      ),
      bundleRelativePath: bundle.relativePath,
      rootPath: plan.root.path,
    );
  }

  Future<void> _writeCodeResources(
    BundlePlan plan,
    ResolvedBundle bundle,
    Uint8List bytes,
  ) async {
    final directory = hostServices.host.fileSystem.directory(
      hostServices.host.paths.context.join(bundle.path, '_CodeSignature'),
    );
    try {
      await directory.create(recursive: true);
    } on Object catch (error) {
      bundleFail(plan.root.path, directory.path, 'could not create: $error');
    }
    await _atomicWrite(
      hostServices.host.paths.context.join(
        bundle.path,
        '_CodeSignature',
        'CodeResources',
      ),
      bytes,
      plan.root.path,
    );
  }

  static int _depth(String relative) =>
      relative == '.' ? 0 : relative.split('/').length;

  Future<void> _removeIfPresent(String path) async {
    final type = hostServices.host.fileSystem.typeSync(
      path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return;
    try {
      if (type == FileSystemEntityType.directory) {
        await hostServices.host.fileSystem
            .directory(path)
            .delete(recursive: true);
      } else if (type == FileSystemEntityType.link) {
        await hostServices.host.fileSystem.link(path).delete();
      } else {
        await hostServices.host.fileSystem.file(path).delete();
      }
    } on Object catch (error) {
      throw AppleError('Could not remove stale signing entry "$path": $error');
    }
  }

  Future<void> _atomicWrite(String path, List<int> bytes, String root) async {
    final temporary = hostServices.host.fileSystem.file(
      '$path.xcross-sign-$pid-${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(hostServices.host.fileSystem.file(path).path);
    } on Object catch (error) {
      if (temporary.existsSync()) await temporary.delete();
      bundleFail(root, path, 'could not atomically write file: $error');
    }
  }
}
