import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/src/shared/signing/bundle_paths.dart';
import 'package:apple_developer_kit/src/shared/signing/bytes.dart';
import 'package:apple_developer_kit/src/shared/signing/internal/bundle_entry.dart';
import 'package:apple_developer_kit/src/shared/signing/plist.dart';
import 'package:cli_kit/shared/platform/file_system_inspection.dart';
import 'package:meta/meta.dart';

/// Directory names that always imply nested code this signer cannot handle.
///
/// `PlugIns` is absent on purpose: embedded app extensions are supported, and
/// are validated by shape instead (a `.appex` directly under `PlugIns/`).
const _forbiddenDirectoryNames = {
  'Watch',
  'WatchKit',
  'com.apple.WatchPlaceholder',
  'Extensions',
  'XPCServices',
};

/// Bundle suffixes that carry their own signature. `.framework` and `.appex`
/// are the nested bundle kinds xcross knows how to sign.
const _unsupportedBundleSuffixes = {
  '.app',
  '.xctest',
  '.xpc',
  '.bundle',
  '.plugin',
  '.xcframework',
};

/// Nested bundle suffixes this signer handles itself.
@internal
const frameworkSuffix = '.framework';
const _appExtensionSuffix = '.appex';

/// The only directory an embedded app extension may live in.
const _plugInsDirectory = 'PlugIns';

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

@internal
class BundleTree {
  BundleTree({required this.hostServices});
  final AppleHostServices hostServices;
  List<BundleEntry> readEntries(String root, String rootReal) {
    final result = <BundleEntry>[];

    void visit(String directory) {
      final children = _sortedChildren(root, directory);
      for (final child in children) {
        final childPath = hostServices.host.paths.context.join(
          directory,
          hostServices.host.paths.context.basename(child.path),
        );
        final type = hostServices.host.fileSystem.typeSync(
          childPath,
          followLinks: false,
        );
        final relativePath = bundleRelativePath(
          root,
          childPath,
          paths: hostServices.host.paths,
        );
        result.add(BundleEntry(childPath, relativePath, type));
        switch (type) {
          case FileSystemEntityType.link:
            _requireLinkInsideBundle(root, rootReal, childPath);
          case FileSystemEntityType.directory:
            visit(childPath);
          case FileSystemEntityType.file:
            _requireReadableFile(root, childPath);
          default:
            bundleFail(
              root,
              childPath,
              'unsupported filesystem entry',
              paths: hostServices.host.paths,
            );
        }
      }
    }

    visit(root);
    result.sort(
      (left, right) => compareUtf8(left.relativePath, right.relativePath),
    );
    return result;
  }

  List<FileSystemEntity> _sortedChildren(String root, String directory) {
    try {
      return hostServices.host.fileSystem
          .directory(directory)
          .listSync(followLinks: false)
          .toList()
        ..sort(
          (left, right) => compareUtf8(
            hostServices.host.paths.context.basename(left.path),
            hostServices.host.paths.context.basename(right.path),
          ),
        );
    } on Object catch (error) {
      bundleFail(
        root,
        directory,
        'could not list directory: $error',
        paths: hostServices.host.paths,
      );
    }
  }

  void _requireLinkInsideBundle(
    String root,
    String rootReal,
    String childPath,
  ) {
    final resolved = _resolveLink(childPath, root);
    final staysInside = isWithinOrEqual(
      rootReal,
      resolved,
      hostServices: hostServices,
    );
    if (!staysInside) {
      bundleFail(
        root,
        childPath,
        'symlink target escapes the app bundle',
        paths: hostServices.host.paths,
      );
    }
  }

  void _requireReadableFile(String root, String childPath) {
    try {
      hostServices.host.fileSystem.file(childPath).readAsBytesSync();
    } on Object catch (error) {
      bundleFail(
        root,
        childPath,
        'could not read file: $error',
        paths: hostServices.host.paths,
      );
    }
  }

  void rejectUnsupportedTree(String root, List<BundleEntry> entries) {
    for (final entry in entries) {
      if (entry.type != FileSystemEntityType.directory) continue;
      final name = hostServices.host.paths.context.basename(entry.path);
      if (_forbiddenDirectoryNames.contains(name)) {
        bundleFail(
          root,
          entry.path,
          'unsupported nested code directory "$name"',
          paths: hostServices.host.paths,
        );
      }
      if (name.endsWith(_appExtensionSuffix)) {
        // A .appex is only loadable from PlugIns/ and only one level deep.
        if (!isEmbeddedAppExtension(entry.relativePath)) {
          bundleFail(
            root,
            entry.path,
            'app extension "$name" must live directly in $_plugInsDirectory/',
            paths: hostServices.host.paths,
          );
        }
        continue;
      }
      if (!name.endsWith(frameworkSuffix) &&
          (_unsupportedBundleSuffixes.any(name.endsWith) ||
              _declaresBundleExecutable(entry.path))) {
        bundleFail(
          root,
          entry.path,
          'unsupported nested code bundle "$name"',
          paths: hostServices.host.paths,
        );
      }
    }
  }

  static bool isEmbeddedAppExtension(String relativePath) {
    final segments = relativePath.split('/');
    return segments.length == 2 &&
        segments.first == _plugInsDirectory &&
        segments.last.endsWith(_appExtensionSuffix);
  }

  bool _declaresBundleExecutable(String directory) {
    final info = hostServices.host.fileSystem.file(
      hostServices.host.paths.context.join(directory, 'Info.plist'),
    );
    if (!info.existsSync()) return false;
    try {
      final plist = decodePropertyList(info.readAsBytesSync());
      return plist is Map<Object?, Object?> &&
          plist['CFBundleExecutable'] is String;
    } on Object {
      return false;
    }
  }

  String resolveDirectory(String path, String root) {
    try {
      return hostServices.host.fileSystem
          .directory(path)
          .resolveSymbolicLinksSync();
    } on Object catch (error) {
      bundleFail(
        root,
        path,
        'could not resolve directory: $error',
        paths: hostServices.host.paths,
      );
    }
  }

  String _resolveLink(String path, String root) {
    try {
      return hostServices.host.fileSystem.link(path).resolveSymbolicLinksSync();
    } on Object catch (error) {
      bundleFail(
        root,
        path,
        'unsafe or dangling symlink: $error',
        paths: hostServices.host.paths,
      );
    }
  }

  bool hasMachOMagic(String path) {
    try {
      final file = hostServices.host.fileSystem.file(path).openSync();
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
}
