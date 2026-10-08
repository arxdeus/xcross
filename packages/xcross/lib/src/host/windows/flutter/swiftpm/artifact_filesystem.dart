import 'dart:ffi';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';

@internal
final class WindowsSwiftPmArtifactFileSystem
    implements SwiftPmArtifactFileSystem {
  WindowsSwiftPmArtifactFileSystem(this.host, this.runner);
  final WindowsHostInterface host;
  final ProcessRunner runner;
  late final int Function(Pointer<Utf16>) getFileAttributes =
      DynamicLibrary.open('kernel32.dll').lookupFunction<
        Uint32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)
      >('GetFileAttributesW');
  @override
  File file(String path) => host.fileSystem.file(host.paths.ioPath(path));
  @override
  Directory directory(String path) =>
      host.fileSystem.directory(host.paths.ioPath(path));
  @override
  Link link(String path) => host.fileSystem.link(host.paths.ioPath(path));
  @override
  FileSystemEntityType typeSync(String path, {bool followLinks = true}) =>
      FileSystemEntity.typeSync(
        host.paths.ioPath(path),
        followLinks: followLinks,
      );
  @override
  Future<bool> isLinkOrReparsePoint(String path) async {
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.link) {
      return true;
    }
    final pointer = host.paths.ioPath(path).toNativeUtf16();
    try {
      final attributes = getFileAttributes(pointer);
      if (attributes == 0xffffffff) {
        throw FileSystemException(
          'Could not read SwiftPM binary artifact attributes',
          path,
        );
      }
      return attributes & 0x400 != 0;
    } finally {
      calloc.free(pointer);
    }
  }

  @override
  Future<void> createAlias(String alias, String target) async {
    final result = await runner.run(await runner.locateTool('cmd.exe'), [
      '/c',
      'mklink',
      '/J',
      p.windows.normalize(alias),
      p.windows.normalize(target),
    ]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Could not create SwiftPM binary artifact junction: ${result.stderr.substring(0, result.stderr.length.clamp(0, 2048))}',
        alias,
      );
    }
  }

  @override
  Future<void> deleteAlias(String alias) async {
    final result = await runner.run(await runner.locateTool('cmd.exe'), [
      '/c',
      'rmdir',
      alias,
    ]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Could not remove SwiftPM binary artifact junction: ${result.stderr.substring(0, result.stderr.length.clamp(0, 2048))}',
        alias,
      );
    }
  }

  @override
  Future<bool> isAliasTo(String alias, String target) async {
    final type = FileSystemEntity.typeSync(alias, followLinks: false);
    if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.link) {
      return false;
    }
    final result = await runner.run(await runner.locateTool('fsutil.exe'), [
      'reparsepoint',
      'query',
      alias,
    ]);
    if (result.exitCode != 0 ||
        !RegExp(
          r'0x0*a0000003\b',
          caseSensitive: false,
        ).hasMatch(result.stdout)) {
      return false;
    }
    try {
      return host.paths.pathKey(
            await directory(alias).resolveSymbolicLinks(),
          ) ==
          host.paths.pathKey(await directory(target).resolveSymbolicLinks());
    } on FileSystemException {
      return false;
    }
  }

  @override
  String processPath(String path) {
    final normalized = p.windows.normalize(p.windows.absolute(path));
    if (normalized.startsWith(r'\\?\UNC\')) {
      return r'\\' + normalized.substring(8);
    }
    if (normalized.startsWith(r'\\?\')) return normalized.substring(4);
    return normalized;
  }
}

@internal
bool isWindowsMountPointReparseOutput(String output) =>
    RegExp(r'0x0*a0000003\b', caseSensitive: false).hasMatch(output);
