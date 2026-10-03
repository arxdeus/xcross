import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/src/shared/signing/bundle_tree.dart';
import 'package:apple_developer_kit/src/signing/bundle_paths.dart';
import 'package:apple_developer_kit/src/signing/bytes.dart';
import 'package:apple_developer_kit/src/signing/internal/bundle_entry.dart';
import 'package:apple_developer_kit/src/signing/internal/bundle_plan.dart';
import 'package:apple_developer_kit/src/signing/internal/loose_binary.dart';
import 'package:apple_developer_kit/src/signing/internal/resolved_bundle.dart';
import 'package:apple_developer_kit/src/signing/macho_signer.dart';
import 'package:apple_developer_kit/src/signing/plist.dart';
import 'package:apple_developer_kit/src/signing/signing_asset.dart';
import 'package:path/path.dart' as p;

class BundleInspector {
  BundleInspector({
    required this.asset,
    required this.hostServices,
    required this.tree,
  });
  final SigningAsset asset;
  final AppleHostServices hostServices;
  final BundleTree tree;
  Future<BundlePlan> inspect(String appPath) async {
    final normalized = _requireAppDirectory(appPath);
    final rootReal = tree.resolveDirectory(normalized, normalized);
    final entries = tree.readEntries(normalized, rootReal);
    tree.rejectUnsupportedTree(normalized, entries);

    final bundles = _readBundles(normalized, entries);
    final executableOwners = _executableOwners(normalized, bundles);
    final candidates = _machoCandidates(normalized, entries, bundles);
    final looseBinaries = _classifyLooseBinaries(
      normalized,
      candidates,
      executableOwners,
      bundles,
    );
    await _preflightBinaries(normalized, bundles, looseBinaries);

    bundles.sort(
      (left, right) => compareUtf8(left.relativePath, right.relativePath),
    );
    return BundlePlan(bundles, looseBinaries);
  }

  static String _requireAppDirectory(String appPath) {
    final normalized = p.normalize(p.absolute(appPath));
    if (!p.basename(normalized).endsWith('.app') ||
        FileSystemEntity.typeSync(normalized, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw AppleError('Bundle "$appPath" must be an existing .app directory.');
    }
    return normalized;
  }

  List<ResolvedBundle> _readBundles(
    String normalized,
    List<BundleEntry> entries,
  ) {
    final root = _readBundle(normalized, normalized, isRoot: true);
    checkApplicationIdentifier(asset, root.identifier, normalized);
    return <ResolvedBundle>[
      root,
      for (final entry in entries)
        if (entry.type == FileSystemEntityType.directory &&
            entry.relativePath.endsWith(frameworkSuffix))
          _readBundle(normalized, entry.path),
      for (final entry in entries)
        if (entry.type == FileSystemEntityType.directory &&
            BundleTree.isEmbeddedAppExtension(entry.relativePath))
          _readBundle(normalized, entry.path, isAppExtension: true),
    ];
  }

  Map<String, ResolvedBundle> _executableOwners(
    String normalized,
    List<ResolvedBundle> bundles,
  ) {
    final owners = <String, ResolvedBundle>{};
    for (final bundle in bundles) {
      final key = pathKey(bundle.executablePath, hostServices: hostServices);
      final previous = owners[key];
      if (previous != null) {
        bundleFail(
          normalized,
          bundle.executablePath,
          'executable is also owned by "${previous.relativePath}"',
        );
      }
      owners[key] = bundle;
    }
    return owners;
  }

  List<String> _machoCandidates(
    String normalized,
    List<BundleEntry> entries,
    List<ResolvedBundle> bundles,
  ) {
    final candidates = <String>[
      for (final entry in entries)
        if (entry.type == FileSystemEntityType.file &&
            tree.hasMachOMagic(entry.path))
          entry.path,
    ];
    // Still root-first here: [bundles] is only sorted once inspection ends.
    for (final bundle in bundles) {
      if (!candidates.any(
        (path) =>
            samePath(path, bundle.executablePath, hostServices: hostServices),
      )) {
        candidates.add(bundle.executablePath);
      }
    }
    return candidates..sort(
      (left, right) => compareUtf8(
        bundleRelativePath(normalized, left),
        bundleRelativePath(normalized, right),
      ),
    );
  }

  List<LooseBinary> _classifyLooseBinaries(
    String normalized,
    List<String> candidates,
    Map<String, ResolvedBundle> executableOwners,
    List<ResolvedBundle> bundles,
  ) {
    final looseBinaries = <LooseBinary>[];
    final owned = <String>{};
    for (final path in candidates) {
      final key = pathKey(path, hostServices: hostServices);
      if (!owned.add(key)) {
        bundleFail(normalized, path, 'binary has duplicate signing ownership');
      }
      if (executableOwners.containsKey(key)) continue;

      final relative = bundleRelativePath(normalized, path);
      final insideNestedBundle = bundles
          .skip(1)
          .any(
            (bundle) =>
                isWithinOrEqual(bundle.path, path, hostServices: hostServices),
          );
      if (!insideNestedBundle && relative.split('/').contains('Frameworks')) {
        looseBinaries.add(LooseBinary(path, relative, p.basename(path)));
      } else {
        bundleFail(normalized, path, 'unknown nested Mach-O code');
      }
    }
    return looseBinaries..sort(
      (left, right) => compareUtf8(left.relativePath, right.relativePath),
    );
  }

  Future<void> _preflightBinaries(
    String normalized,
    List<ResolvedBundle> bundles,
    List<LooseBinary> looseBinaries,
  ) async {
    final allBinaries =
        <String>[
          for (final bundle in bundles) bundle.executablePath,
          for (final dylib in looseBinaries) dylib.path,
        ]..sort(
          (left, right) => compareUtf8(
            bundleRelativePath(normalized, left),
            bundleRelativePath(normalized, right),
          ),
        );
    for (final path in allBinaries) {
      try {
        await MachOSigner(asset, hostServices: hostServices).preflight(path);
      } on AppleError catch (error) {
        throw AppleError(
          'Bundle "${bundleRelativePath(normalized, path)}" failed Mach-O '
          'preflight: ${error.message}',
        );
      }
    }
  }

  ResolvedBundle _readBundle(
    String root,
    String path, {
    bool isRoot = false,
    bool isAppExtension = false,
  }) {
    final infoPath = p.join(path, 'Info.plist');
    if (FileSystemEntity.typeSync(infoPath, followLinks: false) !=
        FileSystemEntityType.file) {
      bundleFail(root, infoPath, 'required Info.plist is missing');
    }
    final Uint8List bytes;
    final Object plist;
    try {
      bytes = hostServices.host.fileSystem.file(infoPath).readAsBytesSync();
      plist = decodePropertyList(bytes);
    } on Object catch (error) {
      bundleFail(root, infoPath, 'malformed Info.plist: $error');
    }
    if (plist is! Map<Object?, Object?>) {
      bundleFail(root, infoPath, 'Info.plist root is not a dictionary');
    }
    final executable = plist['CFBundleExecutable'];
    final identifier = plist['CFBundleIdentifier'];
    // The executable name is joined onto the bundle path, so anything that
    // could traverse out of it is rejected.
    if (executable is! String ||
        executable.isEmpty ||
        executable == '.' ||
        executable == '..' ||
        p.basename(executable) != executable ||
        executable.contains('/') ||
        executable.contains(r'\')) {
      bundleFail(root, infoPath, 'CFBundleExecutable must be a file name');
    }
    if (identifier is! String ||
        identifier.isEmpty ||
        identifier.contains('\u0000')) {
      bundleFail(root, infoPath, 'CFBundleIdentifier is missing or invalid');
    }
    final executablePath = p.join(path, executable);
    if (FileSystemEntity.typeSync(executablePath, followLinks: false) !=
        FileSystemEntityType.file) {
      bundleFail(
        root,
        executablePath,
        'bundle executable is missing or not a file',
      );
    }
    return ResolvedBundle(
      path,
      isRoot ? '.' : bundleRelativePath(root, path),
      identifier,
      executablePath,
      bytes,
      isRoot: isRoot,
      isAppExtension: isAppExtension,
    );
  }

  static void checkApplicationIdentifier(
    SigningAsset asset,
    String bundleIdentifier,
    String root,
  ) {
    final applicationIdentifier = asset.entitlements['application-identifier'];
    if (applicationIdentifier is! String || applicationIdentifier.isEmpty) {
      throw AppleError(
        'Bundle "$root" signing entitlements have no application-identifier.',
      );
    }
    final separator = applicationIdentifier.indexOf('.');
    if (separator <= 0 || separator == applicationIdentifier.length - 1) {
      throw AppleError(
        'Bundle "$root" has invalid signing application-identifier '
        '"$applicationIdentifier".',
      );
    }
    final pattern = applicationIdentifier.substring(separator + 1);
    final matches = pattern.endsWith('*')
        ? bundleIdentifier.startsWith(pattern.substring(0, pattern.length - 1))
        : bundleIdentifier == pattern;
    if (!matches) {
      throw AppleError(
        'Bundle "$root" identifier "$bundleIdentifier" is incompatible with '
        'signing application-identifier "$applicationIdentifier".',
      );
    }
  }
}
