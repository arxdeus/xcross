import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/cli/basic/internal/hard_link_payloads.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/sdk/sdk_archive_links.dart';
import 'package:xcross/src/shared/sdk/sdk_archive_paths.dart';
import 'package:xcross/src/shared/sdk/sdk_install_constants.dart';

final class SdkArchiveExtraction<T extends PlatformHostInterface> {
  SdkArchiveExtraction(this.runner, this.repository, this.links)
    : pathPolicy = SdkArchivePaths(runner.host.paths.context) {
    if (!identical(runner.host, repository.host)) {
      throw ArgumentError(
        'SDK repository and process runner must share a host',
      );
    }
  }
  final ProcessRunner<T> runner;
  final DarwinSdkRepository<T> repository;
  final SdkArchiveLinksInterface links;
  final SdkArchivePaths pathPolicy;
  T get host => runner.host;
  Log get log => runner.log;
  p.Context get _paths => host.paths.context;
  Stream<CpioEntry> xcodeAppEntries(String appPath) async* {
    final sourceContents = _paths.join(appPath, 'Contents');
    if (!host.fileSystem
        .directory(_paths.join(sourceContents, 'Developer'))
        .existsSync()) {
      throw XcrossError('No Xcode Developer directory found in "$appPath".');
    }
    final canonicalApp = await host.fileSystem
        .directory(appPath)
        .resolveSymbolicLinks();
    final contents = await host.fileSystem
        .directory(sourceContents)
        .resolveSymbolicLinks();
    if (!_paths.isWithin(canonicalApp, contents)) {
      throw XcrossError('Xcode SDK source escapes the app: $sourceContents');
    }
    for (final relative in [...sdkIncludedRoots, ...sdkIncludedFiles]) {
      final source = _paths.joinAll([contents, ...relative.split('/')]);
      final type = host.fileSystem.typeSync(source, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      final resolved = switch (type) {
        FileSystemEntityType.directory =>
          await host.fileSystem.directory(source).resolveSymbolicLinks(),
        FileSystemEntityType.file =>
          await host.fileSystem.file(source).resolveSymbolicLinks(),
        _ => source,
      };
      if (!_paths.isWithin(contents, resolved)) {
        throw XcrossError('Xcode SDK source escapes the app: $source');
      }
      yield await _xcodeAppEntry(source, relative, type);
      if (type != FileSystemEntityType.directory) continue;
      await for (final entity
          in host.fileSystem
              .directory(source)
              .list(recursive: true, followLinks: false)) {
        final entityType = host.fileSystem.typeSync(
          entity.path,
          followLinks: false,
        );
        final name = _paths
            .relative(entity.path, from: contents)
            .replaceAll(r'\', '/');
        yield await _xcodeAppEntry(entity.path, name, entityType);
      }
    }
  }

  Future<CpioEntry> _xcodeAppEntry(
    String source,
    String name,
    FileSystemEntityType type,
  ) async {
    switch (type) {
      case FileSystemEntityType.directory:
        return CpioEntry(
          name: name,
          mode: sdkDirectoryFileType | 0x1ed,
          data: Uint8List(0),
        );
      case FileSystemEntityType.link:
        return CpioEntry(
          name: name,
          mode: sdkSymbolicLinkFileType | 0x1ff,
          data: utf8.encode(await host.fileSystem.link(source).target()),
        );
      case FileSystemEntityType.file:
        final file = host.fileSystem.file(source);
        return CpioEntry(
          name: name,
          mode: sdkRegularFileType | (file.statSync().mode & 0x1ff),
          data: await file.readAsBytes(),
        );
      default:
        throw XcrossError('Unsupported Xcode SDK file: $source');
    }
  }

  Future<int> writeSdkEntries(
    Stream<CpioEntry> entries,
    String destDir, {
    void Function(int count)? onProgress,
    void Function(int done, int total)? onLinkProgress,
  }) async {
    final root = _paths.normalize(_paths.absolute(destDir));
    await host.fileSystem.directory(ioPath(root)).create(recursive: true);
    final archiveLinks = <String, String>{};
    final paths = <String, (String, int)>{};
    final hardLinks = HardLinkPayloads();
    final descriptors = <String, String>{};
    var written = 0;
    var patchedStubs = 0;

    await for (final entry in entries) {
      // Runs before the inclusion filter: an excluded entry may still carry
      // the only copy of a payload an included hard link shares.
      final fileType = entry.mode & sdkFileTypeMask;
      var data = hardLinks.payloadFor(
        entry,
        isRegular: fileType == sdkRegularFileType || fileType == 0,
      );
      final destPath = pathPolicy.destinationPath(root, entry);
      if (destPath == null) continue;
      if (fileType == sdkDirectoryFileType ||
          fileType == sdkSymbolicLinkFileType ||
          fileType == sdkRegularFileType ||
          fileType == 0) {
        pathPolicy.recordPath(root, paths, destPath, fileType);
      }
      pathPolicy.recordDescriptorSource(descriptors, destPath, entry.name);

      // Text stubs are rewritten on the way in rather than in a pass over
      // the installed tree: the bytes here are the hard-link group's shared
      // payload, so every member of the group lands patched, and the
      // symlinks Windows materializes later are copied from files that
      // already are.
      if (TbdBundlePatch.isTbdName(destPath)) {
        final rewritten = TbdBundlePatch.rewriteBytes(data);
        if (rewritten != null) {
          data = rewritten;
          patchedStubs++;
        }
      }

      switch (entry.mode & sdkFileTypeMask) {
        case sdkDirectoryFileType:
          await host.fileSystem
              .directory(ioPath(destPath))
              .create(recursive: true);
        case sdkSymbolicLinkFileType:
          await _createParentDirectory(destPath);
          archiveLinks[destPath] = utf8.decode(entry.data);
        case sdkRegularFileType || 0:
          await _createParentDirectory(destPath);
          await host.fileSystem.file(ioPath(destPath)).writeAsBytes(data);
          if (entry.mode & sdkAnyExecuteBit != 0) {
            runner.makeExecutable(destPath);
          }
        default:
          continue;
      }

      written++;
      onProgress?.call(written);
    }

    final resolvedLinks = pathPolicy.resolvedLinks(root, archiveLinks);
    await links.createLinks(resolvedLinks, onProgress: onLinkProgress);
    // Stamped unconditionally: a freshly extracted bundle has been through
    // the rewrite whether or not any stub needed it, and the stamp is what
    // stops every later SDK resolve from rescanning the tree.
    repository.patch.stamp(root, files: patchedStubs);
    if (patchedStubs > 0) {
      log.logTrace(
        'Renamed ${tbdArchitectureAliases.keys.join(', ')} in '
        '$patchedStubs .tbd files',
      );
    }
    return written;
  }

  Future<Directory> _createParentDirectory(String path) => host.fileSystem
      .directory(ioPath(_paths.dirname(path)))
      .create(recursive: true);

  String ioPath(String path) => host.paths.ioPath(path);
}
