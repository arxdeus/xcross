import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/signing/macho_signer.dart';
import 'package:apple_developer_kit/src/signing/signing_asset.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';

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

    final frameworks = plan.bundles.where((bundle) => !bundle.isRoot).toList()
      ..sort((left, right) {
        final depth = _depth(
          right.relativePath,
        ).compareTo(_depth(left.relativePath));
        return depth != 0
            ? depth
            : _compareUtf8(left.relativePath, right.relativePath);
      });
    for (final framework in frameworks) {
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

  Future<_Plan> _inspect(String appPath) async {
    final normalized = p.normalize(p.absolute(appPath));
    if (!p.basename(normalized).endsWith('.app') ||
        FileSystemEntity.typeSync(normalized, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw AppleError('Bundle "$appPath" must be an existing .app directory.');
    }

    final rootReal = _resolveDirectory(normalized, normalized);
    final entries = _walk(normalized, rootReal);
    _rejectUnsupportedTree(normalized, entries);

    final root = _readBundle(normalized, normalized, isRoot: true);
    _checkApplicationIdentifier(root.identifier, normalized);
    final bundles = <_Bundle>[root];
    for (final entry in entries) {
      if (entry.type == FileSystemEntityType.directory &&
          entry.relativePath.endsWith('.framework')) {
        bundles.add(_readBundle(normalized, entry.path));
      }
    }

    final executableOwners = <String, _Bundle>{};
    for (final bundle in bundles) {
      final key = _pathKey(bundle.executablePath);
      final previous = executableOwners[key];
      if (previous != null) {
        _fail(
          normalized,
          bundle.executablePath,
          'executable is also owned by "${previous.relativePath}"',
        );
      }
      executableOwners[key] = bundle;
    }

    final candidates = <String>[];
    for (final entry in entries) {
      if (entry.type == FileSystemEntityType.file &&
          _hasMachOMagic(entry.path)) {
        candidates.add(entry.path);
      }
    }
    if (!candidates.any((path) => _samePath(path, root.executablePath))) {
      candidates.add(root.executablePath);
    }
    for (final bundle in bundles.skip(1)) {
      if (!candidates.any((path) => _samePath(path, bundle.executablePath))) {
        candidates.add(bundle.executablePath);
      }
    }
    candidates.sort(
      (left, right) => _compareUtf8(
        _relative(normalized, left),
        _relative(normalized, right),
      ),
    );

    final looseBinaries = <_LooseBinary>[];
    final owned = <String>{};
    for (final path in candidates) {
      final key = _pathKey(path);
      if (!owned.add(key)) {
        _fail(normalized, path, 'binary has duplicate signing ownership');
      }
      if (executableOwners.containsKey(key)) continue;

      final relative = _relative(normalized, path);
      final components = relative.split('/');
      final insideFramework = bundles
          .skip(1)
          .any((bundle) => _isWithinOrEqual(bundle.path, path));
      if (!insideFramework && components.contains('Frameworks')) {
        looseBinaries.add(_LooseBinary(path, relative, p.basename(path)));
      } else {
        _fail(normalized, path, 'unknown nested Mach-O code');
      }
    }
    looseBinaries.sort(
      (left, right) => _compareUtf8(left.relativePath, right.relativePath),
    );

    final allBinaries =
        <String>[
          for (final bundle in bundles) bundle.executablePath,
          for (final dylib in looseBinaries) dylib.path,
        ]..sort(
          (left, right) => _compareUtf8(
            _relative(normalized, left),
            _relative(normalized, right),
          ),
        );
    for (final path in allBinaries) {
      try {
        await MachOSigner.preflight(path);
      } on AppleError catch (error) {
        throw AppleError(
          'Bundle "${_relative(normalized, path)}" failed Mach-O preflight: '
          '${error.message}',
        );
      }
    }

    bundles.sort(
      (left, right) => _compareUtf8(left.relativePath, right.relativePath),
    );
    return _Plan(normalized, bundles, looseBinaries);
  }

  List<_Entry> _walk(String root, String rootReal) {
    final result = <_Entry>[];

    void visit(String directory) {
      final List<FileSystemEntity> children;
      try {
        children = Directory(directory).listSync(followLinks: false).toList()
          ..sort(
            (left, right) =>
                _compareUtf8(p.basename(left.path), p.basename(right.path)),
          );
      } on Object catch (error) {
        _fail(root, directory, 'could not list directory: $error');
      }
      for (final child in children) {
        final type = FileSystemEntity.typeSync(child.path, followLinks: false);
        final entry = _Entry(child.path, _relative(root, child.path), type);
        result.add(entry);
        if (type == FileSystemEntityType.link) {
          final resolved = _resolveLink(child.path, root);
          if (!_isWithinOrEqual(rootReal, resolved)) {
            _fail(root, child.path, 'symlink target escapes the app bundle');
          }
        } else if (type == FileSystemEntityType.directory) {
          visit(child.path);
        } else if (type == FileSystemEntityType.file) {
          try {
            File(child.path).readAsBytesSync();
          } on Object catch (error) {
            _fail(root, child.path, 'could not read file: $error');
          }
        } else {
          _fail(root, child.path, 'unsupported filesystem entry');
        }
      }
    }

    visit(root);
    result.sort(
      (left, right) => _compareUtf8(left.relativePath, right.relativePath),
    );
    return result;
  }

  void _rejectUnsupportedTree(String root, List<_Entry> entries) {
    const forbiddenNames = {
      'Watch',
      'WatchKit',
      'com.apple.WatchPlaceholder',
      'PlugIns',
      'Extensions',
      'XPCServices',
    };
    const unsupportedSuffixes = {
      '.app',
      '.appex',
      '.xctest',
      '.xpc',
      '.bundle',
      '.plugin',
      '.xcframework',
    };
    for (final entry in entries) {
      if (entry.type != FileSystemEntityType.directory) continue;
      final name = p.basename(entry.path);
      if (forbiddenNames.contains(name)) {
        _fail(root, entry.path, 'unsupported nested code directory "$name"');
      }
      if (!name.endsWith('.framework') &&
          (unsupportedSuffixes.any(name.endsWith) ||
              _declaresBundleExecutable(entry.path))) {
        _fail(root, entry.path, 'unsupported nested code bundle "$name"');
      }
    }
  }

  bool _declaresBundleExecutable(String directory) {
    final info = File(p.join(directory, 'Info.plist'));
    if (!info.existsSync()) return false;
    try {
      final bytes = info.readAsBytesSync();
      final plist =
          bytes.length >= 8 && ascii.decode(bytes.sublist(0, 8)) == 'bplist00'
          ? PropertyListSerialization.propertyListWithData(
              ByteData.sublistView(bytes),
            )
          : PropertyListSerialization.propertyListWithString(
              utf8.decode(bytes),
            );
      return plist is Map<Object?, Object?> &&
          plist['CFBundleExecutable'] is String;
    } on Object {
      return false;
    }
  }

  _Bundle _readBundle(String root, String path, {bool isRoot = false}) {
    final infoPath = p.join(path, 'Info.plist');
    if (FileSystemEntity.typeSync(infoPath, followLinks: false) !=
        FileSystemEntityType.file) {
      _fail(root, infoPath, 'required Info.plist is missing');
    }
    final Uint8List bytes;
    final Object plist;
    try {
      bytes = File(infoPath).readAsBytesSync();
      plist =
          bytes.length >= 8 && ascii.decode(bytes.sublist(0, 8)) == 'bplist00'
          ? PropertyListSerialization.propertyListWithData(
              ByteData.sublistView(bytes),
            )
          : PropertyListSerialization.propertyListWithString(
              utf8.decode(bytes),
            );
    } on Object catch (error) {
      _fail(root, infoPath, 'malformed Info.plist: $error');
    }
    if (plist is! Map<Object?, Object?>) {
      _fail(root, infoPath, 'Info.plist root is not a dictionary');
    }
    final executable = plist['CFBundleExecutable'];
    final identifier = plist['CFBundleIdentifier'];
    if (executable is! String ||
        executable.isEmpty ||
        executable == '.' ||
        executable == '..' ||
        p.basename(executable) != executable ||
        executable.contains('/') ||
        executable.contains(r'\')) {
      _fail(root, infoPath, 'CFBundleExecutable must be a file name');
    }
    if (identifier is! String ||
        identifier.isEmpty ||
        identifier.contains('\u0000')) {
      _fail(root, infoPath, 'CFBundleIdentifier is missing or invalid');
    }
    final executablePath = p.join(path, executable);
    if (FileSystemEntity.typeSync(executablePath, followLinks: false) !=
        FileSystemEntityType.file) {
      _fail(root, executablePath, 'bundle executable is missing or not a file');
    }
    return _Bundle(
      path,
      isRoot ? '.' : _relative(root, path),
      identifier,
      executablePath,
      bytes,
      isRoot: isRoot,
    );
  }

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

  Uint8List _codeResources(_Plan plan, _Bundle bundle) {
    final entries = _walk(
      bundle.path,
      _resolveDirectory(plan.root.path, plan.root.path),
    );
    final files = _sortedMap();
    final files2 = _sortedMap();
    final executable = _relative(bundle.path, bundle.executablePath);
    const codeResources = '_CodeSignature/CodeResources';

    for (final entry in entries) {
      if (entry.type != FileSystemEntityType.file &&
          entry.type != FileSystemEntityType.link) {
        continue;
      }
      final key = entry.relativePath;
      if (key == executable || key == codeResources) continue;
      if (entry.type == FileSystemEntityType.link) {
        final seal = _symlinkSeal(entry.path, plan.root.path);
        if (!_omitFiles1(key)) files[key] = seal;
      } else if (!_omitFiles1(key)) {
        final hash = _sha1File(entry.path, plan.root.path);
        files[key] = _isLocalization(key)
            ? (_sortedMap()
                ..['hash'] = _data(hash)
                ..['optional'] = true)
            : _data(hash);
      }
    }

    for (final entry in entries) {
      if (entry.type != FileSystemEntityType.file &&
          entry.type != FileSystemEntityType.link) {
        continue;
      }
      final key = entry.relativePath;
      if (key == executable || key == codeResources || _omitFiles2(key)) {
        continue;
      }
      if (entry.type == FileSystemEntityType.link) {
        files2[key] = _symlinkSeal(entry.path, plan.root.path);
      } else {
        final value = _sortedMap()
          ..['hash'] = _data(_sha1File(entry.path, plan.root.path))
          ..['hash2'] = _data(_sha256File(entry.path, plan.root.path));
        if (_isLocalization(key)) value['optional'] = true;
        files2[key] = value;
      }
    }

    final output = _sortedMap()
      ..['files'] = files
      ..['files2'] = files2
      ..['rules'] = _rules()
      ..['rules2'] = _rules2();
    try {
      return Uint8List.fromList(
        utf8.encode(PropertyListSerialization.stringWithPropertyList(output)),
      );
    } on Object catch (error) {
      throw AppleError(
        'Bundle "${bundle.relativePath}" could not serialize CodeResources: '
        '$error',
      );
    }
  }

  Future<void> _writeCodeResources(
    _Plan plan,
    _Bundle bundle,
    Uint8List bytes,
  ) async {
    final directory = Directory(p.join(bundle.path, '_CodeSignature'));
    try {
      await directory.create(recursive: true);
    } on Object catch (error) {
      _fail(plan.root.path, directory.path, 'could not create: $error');
    }
    await _atomicWrite(
      p.join(directory.path, 'CodeResources'),
      bytes,
      plan.root.path,
    );
  }

  SplayTreeMap<String, Object?> _rules() => _sortedMap()
    ..['^.*'] = true
    ..[r'^.*\.lproj/'] = (_sortedMap()
      ..['optional'] = true
      ..['weight'] = 1000.0)
    ..[r'^.*\.lproj/locversion.plist$'] = (_sortedMap()
      ..['omit'] = true
      ..['weight'] = 1100.0)
    ..[r'^Base\.lproj/'] = (_sortedMap()..['weight'] = 1010.0)
    ..[r'^version\.plist$'] = true;

  SplayTreeMap<String, Object?> _rules2() => _sortedMap()
    ..['^.*'] = true
    ..[r'.*\.dSYM($|/)'] = (_sortedMap()..['weight'] = 11.0)
    ..[r'^(.*/)?\.DS_Store$'] = (_sortedMap()
      ..['omit'] = true
      ..['weight'] = 2000.0)
    ..[r'^.*\.lproj/'] = (_sortedMap()
      ..['optional'] = true
      ..['weight'] = 1000.0)
    ..[r'^.*\.lproj/locversion.plist$'] = (_sortedMap()
      ..['omit'] = true
      ..['weight'] = 1100.0)
    ..[r'^Base\.lproj/'] = (_sortedMap()..['weight'] = 1010.0)
    ..[r'^Info\.plist$'] = (_sortedMap()
      ..['omit'] = true
      ..['weight'] = 20.0)
    ..[r'^PkgInfo$'] = (_sortedMap()
      ..['omit'] = true
      ..['weight'] = 20.0)
    ..[r'^embedded\.provisionprofile$'] = (_sortedMap()..['weight'] = 20.0)
    ..[r'^version\.plist$'] = (_sortedMap()..['weight'] = 20.0);

  static SplayTreeMap<String, Object?> _sortedMap() =>
      SplayTreeMap<String, Object?>(_compareUtf8);
  static int _compareUtf8(String left, String right) {
    final leftBytes = utf8.encode(left);
    final rightBytes = utf8.encode(right);
    final length = leftBytes.length < rightBytes.length
        ? leftBytes.length
        : rightBytes.length;
    for (var index = 0; index < length; index++) {
      final result = leftBytes[index].compareTo(rightBytes[index]);
      if (result != 0) return result;
    }
    return leftBytes.length.compareTo(rightBytes.length);
  }

  static String _relative(String root, String path) =>
      p.relative(path, from: root).replaceAll(r'\', '/');
  static String _pathKey(String path) {
    final normalized = p.normalize(p.absolute(path));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  static bool _samePath(String left, String right) =>
      _pathKey(left) == _pathKey(right);
  static bool _isWithinOrEqual(String parent, String child) =>
      _samePath(parent, child) || p.isWithin(parent, child);
  static int _depth(String relative) =>
      relative == '.' ? 0 : relative.split('/').length;
  static String _resolveDirectory(String path, String root) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } on Object catch (error) {
      _fail(root, path, 'could not resolve directory: $error');
    }
  }

  static String _resolveLink(String path, String root) {
    try {
      return Link(path).resolveSymbolicLinksSync();
    } on Object catch (error) {
      _fail(root, path, 'unsafe or dangling symlink: $error');
    }
  }

  static bool _hasMachOMagic(String path) {
    try {
      final file = File(path).openSync();
      try {
        final bytes = file.readSync(4);
        if (bytes.length != 4) return false;
        final magic = ByteData.sublistView(bytes).getUint32(0, Endian.little);
        return const {
          0xcafebabe,
          0xbebafeca,
          0xfeedface,
          0xcefaedfe,
          0xfeedfacf,
          0xcffaedfe,
        }.contains(magic);
      } finally {
        file.closeSync();
      }
    } on Object {
      return false;
    }
  }

  static bool _isLocalization(String path) => path.contains('.lproj/');
  static bool _omitFiles1(String path) =>
      path.endsWith('.lproj/locversion.plist');
  static bool _omitFiles2(String path) =>
      path.endsWith('.lproj/locversion.plist') ||
      path.endsWith('.DS_Store') ||
      path == 'Info.plist' ||
      path == 'PkgInfo';
  static ByteData _data(List<int> bytes) =>
      ByteData.sublistView(Uint8List.fromList(bytes));
  static Uint8List _sha1File(String path, String root) {
    try {
      return Uint8List.fromList(
        crypto.sha1.convert(File(path).readAsBytesSync()).bytes,
      );
    } on Object catch (error) {
      _fail(root, path, 'could not hash file with SHA-1: $error');
    }
  }

  static Uint8List _sha256File(String path, String root) {
    try {
      return Uint8List.fromList(
        crypto.sha256.convert(File(path).readAsBytesSync()).bytes,
      );
    } on Object catch (error) {
      _fail(root, path, 'could not hash file with SHA-256: $error');
    }
  }

  static SplayTreeMap<String, Object?> _symlinkSeal(String path, String root) {
    final String target;
    try {
      target = Link(path).targetSync();
    } on Object catch (error) {
      _fail(root, path, 'could not read symlink target: $error');
    }
    return _sortedMap()..['symlink'] = target;
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
      _fail(root, path, 'could not atomically write file: $error');
    }
  }

  static Never _fail(String root, String path, String reason) =>
      throw AppleError(
        'Bundle "${_relative(root, path)}" is invalid: $reason.',
      );
}

class _Plan {
  const _Plan(this.path, this.bundles, this.looseBinaries);

  final String path;
  final List<_Bundle> bundles;
  final List<_LooseBinary> looseBinaries;

  _Bundle get root => bundles.singleWhere((bundle) => bundle.isRoot);
}

class _Bundle {
  const _Bundle(
    this.path,
    this.relativePath,
    this.identifier,
    this.executablePath,
    this.infoPlistBytes, {
    required this.isRoot,
  });

  final String path;
  final String relativePath;
  final String identifier;
  final String executablePath;
  final Uint8List infoPlistBytes;
  final bool isRoot;
}

class _LooseBinary {
  const _LooseBinary(this.path, this.relativePath, this.identifier);

  final String path;
  final String relativePath;
  final String identifier;
}

class _Entry {
  const _Entry(this.path, this.relativePath, this.type);

  final String path;
  final String relativePath;
  final FileSystemEntityType type;
}
