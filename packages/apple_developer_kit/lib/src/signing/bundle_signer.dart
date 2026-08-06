import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/signing/bundle_paths.dart';
import 'package:apple_developer_kit/src/signing/bytes.dart';
import 'package:apple_developer_kit/src/signing/code_resources.dart';
import 'package:apple_developer_kit/src/signing/internal/bundle_entry.dart';
import 'package:apple_developer_kit/src/signing/internal/bundle_plan.dart';
import 'package:apple_developer_kit/src/signing/internal/loose_binary.dart';
import 'package:apple_developer_kit/src/signing/internal/resolved_bundle.dart';
import 'package:apple_developer_kit/src/signing/macho_signer.dart';
import 'package:apple_developer_kit/src/signing/plist.dart';
import 'package:apple_developer_kit/src/signing/signing_asset.dart';
import 'package:path/path.dart' as p;

/// Directory names that always imply nested code this signer cannot handle.
const _forbiddenDirectoryNames = {
  'Watch',
  'WatchKit',
  'com.apple.WatchPlaceholder',
  'PlugIns',
  'Extensions',
  'XPCServices',
};

/// Bundle suffixes that carry their own signature. `.framework` is the only
/// nested bundle kind xcross knows how to sign.
const _unsupportedBundleSuffixes = {
  '.app',
  '.appex',
  '.xctest',
  '.xpc',
  '.bundle',
  '.plugin',
  '.xcframework',
};

/// Every Mach-O magic, read little-endian: fat and thin, 32- and 64-bit, both
/// byte orders. Anything matching is code that would need a signature.
const _machoMagics = {
  0xCAFE_BABE,
  0xBEBA_FECA,
  0xFEED_FACE,
  0xCEFA_EDFE,
  0xFEED_FACF,
  0xCFFA_EDFE,
};

/// Signs the constrained `.app` layout produced by xcross's FlutterPacker.
class BundleSigner {
  BundleSigner(this.asset) : _machoSigner = MachOSigner(asset);

  final SigningAsset asset;
  final MachOSigner _machoSigner;

  /// Validates the whole bundle without changing it.
  Future<void> preflight(String appPath) async {
    await _inspect(appPath);
  }

  /// Signs nested frameworks and dylibs before sealing and signing the app.
  Future<void> signApp(String appPath, {DateTime? signingTime}) async {
    final plan = await _inspect(appPath);

    for (final bundle in plan.bundles) {
      await _removeIfPresent(p.join(bundle.path, '_CodeSignature'));
      if (!bundle.isRoot) {
        await _removeIfPresent(p.join(bundle.path, 'embedded.mobileprovision'));
      }
    }
    await _atomicWrite(
      p.join(plan.root.path, 'embedded.mobileprovision'),
      asset.profileCmsBytes,
      plan.root.path,
    );

    // A bundle seals its children's signatures into its own CodeResources, so
    // the deepest nested code must be finished before its parent is sealed.
    for (final framework in _deepestFirst(plan)) {
      final resources = _codeResources(plan, framework);
      await _writeCodeResources(plan, framework, resources);
      await _machoSigner.signFile(
        framework.executablePath,
        identifier: framework.identifier,
        teamIdentifier: asset.teamIdentifier,
        entitlements: const {},
        infoPlistBytes: framework.infoPlistBytes,
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

  /// Nested bundles ordered deepest first, then by path, so signing is
  /// deterministic across filesystems.
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

  /// Validates the bundle and resolves everything [signApp] will touch.
  ///
  /// Nothing here mutates the bundle: the whole tree is rejected or accepted
  /// before signing begins, so a bad input never leaves a half-signed app.
  Future<BundlePlan> _inspect(String appPath) async {
    final normalized = _requireAppDirectory(appPath);
    final rootReal = _resolveDirectory(normalized, normalized);
    final entries = _walk(normalized, rootReal);
    _rejectUnsupportedTree(normalized, entries);

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

  /// The root app plus every nested `.framework`.
  List<ResolvedBundle> _readBundles(
    String normalized,
    List<BundleEntry> entries,
  ) {
    final root = _readBundle(normalized, normalized, isRoot: true);
    _checkApplicationIdentifier(root.identifier, normalized);
    return <ResolvedBundle>[
      root,
      for (final entry in entries)
        if (entry.type == FileSystemEntityType.directory &&
            entry.relativePath.endsWith('.framework'))
          _readBundle(normalized, entry.path),
    ];
  }

  /// Rejects two bundles claiming the same executable, which would make the
  /// signing order ambiguous.
  static Map<String, ResolvedBundle> _executableOwners(
    String normalized,
    List<ResolvedBundle> bundles,
  ) {
    final owners = <String, ResolvedBundle>{};
    for (final bundle in bundles) {
      final key = pathKey(bundle.executablePath);
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

  /// Every file that looks like Mach-O, plus each declared executable even if
  /// its magic could not be read.
  static List<String> _machoCandidates(
    String normalized,
    List<BundleEntry> entries,
    List<ResolvedBundle> bundles,
  ) {
    final candidates = <String>[
      for (final entry in entries)
        if (entry.type == FileSystemEntityType.file &&
            _hasMachOMagic(entry.path))
          entry.path,
    ];
    // Still root-first here: [bundles] is only sorted once inspection ends.
    for (final bundle in bundles) {
      if (!candidates.any((path) => samePath(path, bundle.executablePath))) {
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

  /// Sorts every Mach-O into "owned by a bundle" or "loose dylib", rejecting
  /// stray code that would ship unsigned.
  static List<LooseBinary> _classifyLooseBinaries(
    String normalized,
    List<String> candidates,
    Map<String, ResolvedBundle> executableOwners,
    List<ResolvedBundle> bundles,
  ) {
    final looseBinaries = <LooseBinary>[];
    final owned = <String>{};
    for (final path in candidates) {
      final key = pathKey(path);
      if (!owned.add(key)) {
        bundleFail(normalized, path, 'binary has duplicate signing ownership');
      }
      if (executableOwners.containsKey(key)) continue;

      final relative = bundleRelativePath(normalized, path);
      final insideFramework = bundles
          .skip(1)
          .any((bundle) => isWithinOrEqual(bundle.path, path));
      if (!insideFramework && relative.split('/').contains('Frameworks')) {
        looseBinaries.add(LooseBinary(path, relative, p.basename(path)));
      } else {
        bundleFail(normalized, path, 'unknown nested Mach-O code');
      }
    }
    return looseBinaries..sort(
      (left, right) => compareUtf8(left.relativePath, right.relativePath),
    );
  }

  /// Preflights every binary before any of them is rewritten.
  static Future<void> _preflightBinaries(
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
        await MachOSigner.preflight(path);
      } on AppleError catch (error) {
        throw AppleError(
          'Bundle "${bundleRelativePath(normalized, path)}" failed Mach-O '
          'preflight: ${error.message}',
        );
      }
    }
  }

  /// Lists the tree under [root], refusing symlinks that escape the bundle and
  /// files that cannot be read.
  List<BundleEntry> _walk(String root, String rootReal) {
    final result = <BundleEntry>[];

    void visit(String directory) {
      final List<FileSystemEntity> children;
      try {
        children = Directory(directory).listSync(followLinks: false).toList()
          ..sort(
            (left, right) =>
                compareUtf8(p.basename(left.path), p.basename(right.path)),
          );
      } on Object catch (error) {
        bundleFail(root, directory, 'could not list directory: $error');
      }
      for (final child in children) {
        final type = FileSystemEntity.typeSync(child.path, followLinks: false);
        result.add(
          BundleEntry(child.path, bundleRelativePath(root, child.path), type),
        );
        switch (type) {
          case FileSystemEntityType.link:
            final resolved = _resolveLink(child.path, root);
            if (!isWithinOrEqual(rootReal, resolved)) {
              bundleFail(
                root,
                child.path,
                'symlink target escapes the app bundle',
              );
            }
          case FileSystemEntityType.directory:
            visit(child.path);
          case FileSystemEntityType.file:
            try {
              File(child.path).readAsBytesSync();
            } on Object catch (error) {
              bundleFail(root, child.path, 'could not read file: $error');
            }
          default:
            bundleFail(root, child.path, 'unsupported filesystem entry');
        }
      }
    }

    visit(root);
    result.sort(
      (left, right) => compareUtf8(left.relativePath, right.relativePath),
    );
    return result;
  }

  void _rejectUnsupportedTree(String root, List<BundleEntry> entries) {
    for (final entry in entries) {
      if (entry.type != FileSystemEntityType.directory) continue;
      final name = p.basename(entry.path);
      if (_forbiddenDirectoryNames.contains(name)) {
        bundleFail(
          root,
          entry.path,
          'unsupported nested code directory "$name"',
        );
      }
      if (!name.endsWith('.framework') &&
          (_unsupportedBundleSuffixes.any(name.endsWith) ||
              _declaresBundleExecutable(entry.path))) {
        bundleFail(root, entry.path, 'unsupported nested code bundle "$name"');
      }
    }
  }

  /// True when a directory carries an `Info.plist` naming an executable, which
  /// makes it a code bundle whatever its suffix is.
  bool _declaresBundleExecutable(String directory) {
    final info = File(p.join(directory, 'Info.plist'));
    if (!info.existsSync()) return false;
    try {
      final plist = decodePropertyList(info.readAsBytesSync());
      return plist is Map<Object?, Object?> &&
          plist['CFBundleExecutable'] is String;
    } on Object {
      return false;
    }
  }

  ResolvedBundle _readBundle(String root, String path, {bool isRoot = false}) {
    final infoPath = p.join(path, 'Info.plist');
    if (FileSystemEntity.typeSync(infoPath, followLinks: false) !=
        FileSystemEntityType.file) {
      bundleFail(root, infoPath, 'required Info.plist is missing');
    }
    final Uint8List bytes;
    final Object plist;
    try {
      bytes = File(infoPath).readAsBytesSync();
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
    );
  }

  /// The profile's `application-identifier` is `<team>.<bundle id pattern>`,
  /// where a trailing `*` makes it a wildcard profile.
  void _checkApplicationIdentifier(String bundleIdentifier, String root) {
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

  /// Seals [bundle]'s own contents. Symlink containment is still judged
  /// against the app root, not the nested bundle.
  Uint8List _codeResources(BundlePlan plan, ResolvedBundle bundle) {
    final entries = _walk(
      bundle.path,
      _resolveDirectory(plan.root.path, plan.root.path),
    );
    return buildCodeResources(
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
    final directory = Directory(p.join(bundle.path, '_CodeSignature'));
    try {
      await directory.create(recursive: true);
    } on Object catch (error) {
      bundleFail(plan.root.path, directory.path, 'could not create: $error');
    }
    await _atomicWrite(
      p.join(directory.path, 'CodeResources'),
      bytes,
      plan.root.path,
    );
  }

  static int _depth(String relative) =>
      relative == '.' ? 0 : relative.split('/').length;

  static String _resolveDirectory(String path, String root) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } on Object catch (error) {
      bundleFail(root, path, 'could not resolve directory: $error');
    }
  }

  static String _resolveLink(String path, String root) {
    try {
      return Link(path).resolveSymbolicLinksSync();
    } on Object catch (error) {
      bundleFail(root, path, 'unsafe or dangling symlink: $error');
    }
  }

  /// Deliberately treats an unreadable file as "not Mach-O": the walk has
  /// already proven every file readable, so this only guards races.
  static bool _hasMachOMagic(String path) {
    try {
      final file = File(path).openSync();
      try {
        final bytes = file.readSync(4);
        if (bytes.length != 4) return false;
        final magic = ByteData.sublistView(bytes).getUint32(0, Endian.little);
        return _machoMagics.contains(magic);
      } finally {
        file.closeSync();
      }
    } on Object {
      return false;
    }
  }

  static Future<void> _removeIfPresent(String path) async {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    try {
      if (type == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else if (type == FileSystemEntityType.link) {
        await Link(path).delete();
      } else {
        await File(path).delete();
      }
    } on Object catch (error) {
      throw AppleError('Could not remove stale signing entry "$path": $error');
    }
  }

  /// Writes through a sibling temporary file so a crash cannot leave a
  /// partially written seal behind.
  static Future<void> _atomicWrite(
    String path,
    List<int> bytes,
    String root,
  ) async {
    final temporary = File(
      '$path.xcross-sign-$pid-${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(path);
    } on Object catch (error) {
      if (temporary.existsSync()) await temporary.delete();
      bundleFail(root, path, 'could not atomically write file: $error');
    }
  }
}
