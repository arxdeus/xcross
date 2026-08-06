import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/signing/bundle_paths.dart';
import 'package:apple_developer_kit/src/signing/bytes.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';
import 'package:propertylistserialization/propertylistserialization.dart';

/// One sealable item found while walking a bundle: a regular file or a
/// symlink. Directories are not sealed.
@internal
@immutable
final class SealCandidate {
  const SealCandidate({
    required this.path,
    required this.relativePath,
    required this.isSymlink,
  });

  final String path;
  final String relativePath;
  final bool isSymlink;
}

/// The seal file never seals itself.
const String codeResourcesPath = '_CodeSignature/CodeResources';

/// Builds the `_CodeSignature/CodeResources` property list for one bundle.
///
/// Two seal sets are emitted for compatibility: `files` is the original
/// SHA-1-only format, and `files2` adds a SHA-256 `hash2` and omits more
/// build residue. Both are keyed by bundle-relative path.
@internal
@useResult
Uint8List buildCodeResources({
  required List<SealCandidate> candidates,
  required String executableRelativePath,
  required String bundleRelativePath,
  required String rootPath,
}) {
  final files = sortedPlistMap();
  final files2 = sortedPlistMap();

  for (final candidate in candidates) {
    final key = candidate.relativePath;
    if (key == executableRelativePath || key == codeResourcesPath) continue;
    if (candidate.isSymlink) {
      // Resolved before the omit check so a broken symlink is still reported.
      final seal = _symlinkSeal(candidate.path, rootPath);
      if (!_omitFromFiles(key)) files[key] = seal;
    } else if (!_omitFromFiles(key)) {
      final hash = _sha1File(candidate.path, rootPath);
      files[key] = _isLocalization(key)
          ? (sortedPlistMap()
              ..['hash'] = _data(hash)
              ..['optional'] = true)
          : _data(hash);
    }
  }

  for (final candidate in candidates) {
    final key = candidate.relativePath;
    if (key == executableRelativePath ||
        key == codeResourcesPath ||
        _omitFromFiles2(key)) {
      continue;
    }
    if (candidate.isSymlink) {
      files2[key] = _symlinkSeal(candidate.path, rootPath);
    } else {
      final value = sortedPlistMap()
        ..['hash'] = _data(_sha1File(candidate.path, rootPath))
        ..['hash2'] = _data(_sha256File(candidate.path, rootPath));
      if (_isLocalization(key)) value['optional'] = true;
      files2[key] = value;
    }
  }

  final output = sortedPlistMap()
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
      'Bundle "$bundleRelativePath" could not serialize CodeResources: '
      '$error',
    );
  }
}

/// Apple's default sealing rules for the legacy `files` set.
SplayTreeMap<String, Object?> _rules() => sortedPlistMap()
  ..['^.*'] = true
  ..[r'^.*\.lproj/'] = (sortedPlistMap()
    ..['optional'] = true
    ..['weight'] = 1000.0)
  ..[r'^.*\.lproj/locversion.plist$'] = (sortedPlistMap()
    ..['omit'] = true
    ..['weight'] = 1100.0)
  ..[r'^Base\.lproj/'] = (sortedPlistMap()..['weight'] = 1010.0)
  ..[r'^version\.plist$'] = true;

/// Apple's default sealing rules for `files2`, which additionally drops
/// `.DS_Store`, `Info.plist`, and `PkgInfo`.
SplayTreeMap<String, Object?> _rules2() => sortedPlistMap()
  ..['^.*'] = true
  ..[r'.*\.dSYM($|/)'] = (sortedPlistMap()..['weight'] = 11.0)
  ..[r'^(.*/)?\.DS_Store$'] = (sortedPlistMap()
    ..['omit'] = true
    ..['weight'] = 2000.0)
  ..[r'^.*\.lproj/'] = (sortedPlistMap()
    ..['optional'] = true
    ..['weight'] = 1000.0)
  ..[r'^.*\.lproj/locversion.plist$'] = (sortedPlistMap()
    ..['omit'] = true
    ..['weight'] = 1100.0)
  ..[r'^Base\.lproj/'] = (sortedPlistMap()..['weight'] = 1010.0)
  ..[r'^Info\.plist$'] = (sortedPlistMap()
    ..['omit'] = true
    ..['weight'] = 20.0)
  ..[r'^PkgInfo$'] = (sortedPlistMap()
    ..['omit'] = true
    ..['weight'] = 20.0)
  ..[r'^embedded\.provisionprofile$'] = (sortedPlistMap()..['weight'] = 20.0)
  ..[r'^version\.plist$'] = (sortedPlistMap()..['weight'] = 20.0);

/// Keys are ordered by their UTF-8 bytes, not Dart's UTF-16 [String.compareTo],
/// so the serialized plist matches what Apple's codesign emits.
@internal
@useResult
SplayTreeMap<String, Object?> sortedPlistMap() =>
    SplayTreeMap<String, Object?>(compareUtf8);

bool _isLocalization(String path) => path.contains('.lproj/');

bool _omitFromFiles(String path) => path.endsWith('.lproj/locversion.plist');

bool _omitFromFiles2(String path) =>
    path.endsWith('.lproj/locversion.plist') ||
    path.endsWith('.DS_Store') ||
    path == 'Info.plist' ||
    path == 'PkgInfo';

ByteData _data(List<int> bytes) =>
    ByteData.sublistView(Uint8List.fromList(bytes));

Uint8List _sha1File(String path, String root) {
  try {
    return Uint8List.fromList(
      crypto.sha1.convert(File(path).readAsBytesSync()).bytes,
    );
  } on Object catch (error) {
    bundleFail(root, path, 'could not hash file with SHA-1: $error');
  }
}

Uint8List _sha256File(String path, String root) {
  try {
    return Uint8List.fromList(
      crypto.sha256.convert(File(path).readAsBytesSync()).bytes,
    );
  } on Object catch (error) {
    bundleFail(root, path, 'could not hash file with SHA-256: $error');
  }
}

/// Symlinks are sealed by their literal target text, not by content.
SplayTreeMap<String, Object?> _symlinkSeal(String path, String root) {
  final String target;
  try {
    target = Link(path).targetSync();
  } on Object catch (error) {
    bundleFail(root, path, 'could not read symlink target: $error');
  }
  return sortedPlistMap()..['symlink'] = target;
}
