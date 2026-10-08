import 'package:darwin_sdk_kit/shared/archive/cpio_reader.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/sdk/sdk_install_constants.dart';

@internal
final class SdkArchivePaths {
  const SdkArchivePaths(this._paths);
  final p.Context _paths;
  static String? sdkRelativePath(String name) {
    final archiveName = name.replaceAll(r'\', '/');
    if (_includedFileFor(archiveName) case final file?) return file;
    for (final root in sdkIncludedRoots) {
      if (archiveName == root || archiveName.startsWith('$root/')) {
        return archiveName;
      }
      // Otherwise the root may sit under a prefix such as `Xcode.app/
      // Contents/`; take the first occurrence that ends on a path boundary.
      final anchor = '/$root';
      var index = archiveName.indexOf(anchor);
      while (index >= 0) {
        final end = index + anchor.length;
        if (end == archiveName.length || archiveName[end] == '/') {
          return archiveName.substring(index + 1);
        }
        index = archiveName.indexOf(anchor, index + 1);
      }
    }
    return null;
  }

  static String? _includedFileFor(String archiveName) {
    final firstDeveloper = archiveName.indexOf('/Developer/');
    for (final file in sdkIncludedFiles) {
      if (archiveName == file) return file;
      if (firstDeveloper >= 0 &&
          archiveName.indexOf('/$file', firstDeveloper) == firstDeveloper) {
        return file;
      }
    }
    return null;
  }

  void recordDescriptorSource(
    Map<String, String> descriptors,
    String destPath,
    String entryName,
  ) {
    final isDescriptor = sdkIncludedFiles.any(
      (file) => destPath.endsWith(file.replaceAll('/', _paths.separator)),
    );
    if (!isDescriptor) return;
    final previous = descriptors[destPath];
    if (previous != null && previous != entryName) {
      throw XcrossError(
        'Conflicting SDK descriptor entries: $previous and $entryName',
      );
    }
    descriptors[destPath] = entryName;
  }

  String? destinationPath(String root, CpioEntry entry) {
    final archivePath = sdkRelativePath(entry.name);
    if (archivePath == null) return null;
    if (archivePath.split('/').contains('..')) {
      throw XcrossError('Unsafe SDK archive path: ${entry.name}');
    }
    final relative = _paths.normalize(
      archivePath.replaceAll('/', _paths.separator),
    );
    final destPath = _paths.normalize(_paths.join(root, relative));
    if (_paths.isAbsolute(relative) || !_paths.isWithin(root, destPath)) {
      throw XcrossError('Unsafe SDK archive path: ${entry.name}');
    }
    return destPath;
  }

  Set<String> materializedAliases(String root, Map<String, String> links) {
    final aliases = <String>{};
    final versioned = RegExp(r'^(.+?)[0-9]+(?:\.[0-9]+)*\.sdk$');
    for (final link in resolvedLinks(root, links).entries) {
      final target = link.value;
      final parent = _paths.dirname(link.key);
      if (!_paths.isWithin(root, link.key) ||
          _paths.basename(parent) != 'SDKs' ||
          parent != _paths.dirname(target)) {
        continue;
      }
      final linkName = _paths.basename(link.key);
      final targetName = _paths.basename(target);
      final linkVersion = versioned.firstMatch(linkName);
      final targetVersion = versioned.firstMatch(targetName);
      if (linkVersion != null && targetName == '${linkVersion[1]}.sdk') {
        aliases.add(target);
      } else if (targetVersion != null &&
          linkName == '${targetVersion[1]}.sdk') {
        aliases.add(link.key);
      }
    }
    return aliases;
  }

  Map<String, String> resolvedLinks(String root, Map<String, String> links) {
    final folded = <String, String>{};
    for (final link in links.entries) {
      if (!_paths.isWithin(root, link.key)) {
        throw XcrossError('SDK symlink is outside the SDK: ${link.key}');
      }
      final key = link.key.toLowerCase();
      if (folded.containsKey(key)) {
        throw XcrossError('Case-ambiguous SDK symlinks: ${link.key}');
      }
      folded[key] = link.value;
    }
    for (final link in links.keys) {
      var parent = _paths.dirname(link);
      while (_paths.isWithin(root, parent)) {
        if (folded.containsKey(parent.toLowerCase())) {
          throw XcrossError('Overlapping SDK symlinks: $link');
        }
        parent = _paths.dirname(parent);
      }
    }
    return {
      for (final link in links.keys)
        link: _resolvedSdkLinkPath(root, link, folded),
    };
  }

  void recordPath(
    String root,
    Map<String, (String, int)> paths,
    String path,
    int type,
  ) {
    var candidate = path;
    var candidateType = type == 0 ? sdkRegularFileType : type;
    while (_paths.isWithin(root, candidate)) {
      final key = candidate.toLowerCase();
      final previous = paths[key];
      if (previous != null &&
          (previous.$1 != candidate || previous.$2 != candidateType)) {
        throw XcrossError('Ambiguous SDK entry path: $path');
      }
      paths[key] = (candidate, candidateType);
      candidate = _paths.dirname(candidate);
      candidateType = sdkDirectoryFileType;
    }
  }

  String _resolvedSdkLinkPath(
    String root,
    String path,
    Map<String, String> links,
  ) {
    final components = _paths.split(_paths.relative(path, from: root));
    final resolved = <String>[];
    var expansions = 0;
    while (components.isNotEmpty) {
      final component = components.removeAt(0);
      if (component.isEmpty || component == '.') continue;
      if (component == '..') {
        if (resolved.isEmpty) {
          throw XcrossError('SDK symlink escapes the SDK: $path');
        }
        resolved.removeLast();
        continue;
      }
      resolved.add(component);
      final candidate = _paths.joinAll([root, ...resolved]);
      final target = links[candidate.toLowerCase()];
      if (target == null) continue;
      if (++expansions > 40) {
        throw XcrossError('SDK symlink cycle or excessive chain: $path');
      }
      final targetPath = target.replaceAll('/', _paths.separator);
      if (_paths.isAbsolute(targetPath)) {
        throw XcrossError('SDK symlink target is absolute: $target');
      }
      resolved.removeLast();
      components.insertAll(0, _paths.split(targetPath));
    }
    final result = _paths.joinAll([root, ...resolved]);
    if (result != root && !_paths.isWithin(root, result)) {
      throw XcrossError('SDK symlink escapes the SDK: $path');
    }
    return result;
  }
}
