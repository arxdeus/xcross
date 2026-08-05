import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/util/errors.dart';

/// The iOS subset required by Swift's Linux cross-SDK protocol.
const sdkIncludedRoots = <String>[
  'Developer/Platforms/iPhoneOS.platform/Developer/SDKs',
  'Developer/Platforms/iPhoneOS.platform/Developer/Library/Frameworks',
  'Developer/Platforms/iPhoneOS.platform/Developer/Library/PrivateFrameworks',
  'Developer/Platforms/iPhoneOS.platform/Developer/usr/lib',
  'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift',
  'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift_static',
  'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang',
  'Developer/Toolchains/XcodeDefault.xctoolchain/usr/include',
];

const _platformDeveloper = 'Developer/Platforms/iPhoneOS.platform/Developer';
const _toolchain = 'Developer/Toolchains/XcodeDefault.xctoolchain';
const _swiftResources = '$_toolchain/usr/lib/swift';
const _swiftStaticResources = '$_toolchain/usr/lib/swift_static';

/// POSIX `st_mode` bits carried by every cpio entry.
const _fileTypeMask = 0xF000;
const _directoryType = 0x4000;
const _regularFileType = 0x8000;
const _symbolicLinkType = 0xA000;
const _anyExecuteBit = 0x049; // u+x | g+x | o+x

const _json = JsonEncoder.withIndent('  ');

/// Helpers for extracting and wiring the Darwin Swift SDK bundle.
abstract final class SdkInstall {
  /// Destination-relative path for an included cpio entry, or null when the
  /// entry is outside [sdkIncludedRoots].
  static String? sdkRelativePath(String name) {
    final archiveName = name.replaceAll(r'\', '/');
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

  static Future<int> writeSdkEntries(
    Stream<CpioEntry> entries,
    String destDir, {
    bool? materializeLinks,
    void Function(int count)? onProgress,
  }) async {
    final root = p.normalize(p.absolute(destDir));
    await Directory(ioPath(root)).create(recursive: true);
    final links = <String, String>{};
    final hardLinks = _HardLinkPayloads();
    var written = 0;

    await for (final entry in entries) {
      // Runs before the inclusion filter: an excluded entry may still carry
      // the only copy of a payload an included hard link shares.
      final data = hardLinks.payloadFor(entry);
      final destPath = _destinationPath(root, entry);
      if (destPath == null) continue;

      switch (entry.mode & _fileTypeMask) {
        case _directoryType:
          await Directory(ioPath(destPath)).create(recursive: true);
        case _symbolicLinkType:
          await _createParentDirectory(destPath);
          links[destPath] = utf8.decode(entry.data);
        case _regularFileType || 0:
          await _createParentDirectory(destPath);
          await File(ioPath(destPath)).writeAsBytes(data);
          if (entry.mode & _anyExecuteBit != 0) {
            ProcessRunner.makeExecutable(destPath);
          }
        default:
          continue;
      }

      written++;
      onProgress?.call(written);
    }

    if (materializeLinks ?? Platform.isWindows) {
      await _materializeSdkLinks(root, links);
    } else {
      for (final link in links.entries) {
        _resolvedSdkLinkTarget(root, link.key, link.value);
        await Link(link.key).create(link.value, recursive: true);
      }
    }
    return written;
  }

  /// Absolute destination for an included cpio entry, or null when the entry
  /// is outside [sdkIncludedRoots].
  ///
  /// Rejects `..` segments and anything resolving outside [root] so a hostile
  /// archive cannot write over arbitrary host files.
  static String? _destinationPath(String root, CpioEntry entry) {
    final archivePath = sdkRelativePath(entry.name);
    if (archivePath == null) return null;
    if (archivePath.split('/').contains('..')) {
      throw XcrossError('Unsafe SDK archive path: ${entry.name}');
    }
    final relative = p.normalize(archivePath.replaceAll('/', p.separator));
    final destPath = p.normalize(p.join(root, relative));
    if (p.isAbsolute(relative) || !p.isWithin(root, destPath)) {
      throw XcrossError('Unsafe SDK archive path: ${entry.name}');
    }
    return destPath;
  }

  /// Windows has no usable unprivileged symlink, so every link becomes a copy
  /// of its target. Targets may themselves be links, so this loops until no
  /// link makes progress; a directory waits until nothing else links inside it.
  static Future<void> _materializeSdkLinks(
    String root,
    Map<String, String> links,
  ) async {
    final pending = Map<String, String>.from(links);
    while (pending.isNotEmpty) {
      var progressed = false;
      for (final link in pending.entries.toList()) {
        final target = _resolvedSdkLinkTarget(root, link.key, link.value);
        final type = FileSystemEntity.typeSync(ioPath(target));
        if (type == FileSystemEntityType.notFound) continue;
        if (type == FileSystemEntityType.directory &&
            pending.keys.any(
              (other) => other != link.key && p.isWithin(target, other),
            )) {
          continue;
        }

        switch (type) {
          case FileSystemEntityType.directory:
            await _copySdkDirectory(target, link.key);
          case FileSystemEntityType.file:
            await File(ioPath(target)).copy(ioPath(link.key));
          default:
            throw XcrossError('Unsupported SDK symlink target: ${link.value}');
        }
        pending.remove(link.key);
        progressed = true;
      }
      if (!progressed) {
        throw XcrossError(
          'Could not resolve SDK symlinks: ${pending.values.join(', ')}',
        );
      }
    }
  }

  /// Resolves a link target and rejects anything reaching outside the bundle.
  static String _resolvedSdkLinkTarget(
    String root,
    String link,
    String rawTarget,
  ) {
    final targetPath = rawTarget.replaceAll('/', p.separator);
    if (p.isAbsolute(targetPath)) {
      throw XcrossError('SDK symlink target is absolute: $rawTarget');
    }
    final target = p.normalize(p.join(p.dirname(link), targetPath));
    if (!p.isWithin(root, target)) {
      throw XcrossError('SDK symlink escapes the SDK: $rawTarget');
    }
    return target;
  }

  static Future<void> _copySdkDirectory(
    String source,
    String destination,
  ) async {
    await Directory(ioPath(destination)).create(recursive: true);
    await for (final entity in Directory(ioPath(source)).list()) {
      final target = p.join(destination, p.basename(entity.path));
      switch (FileSystemEntity.typeSync(entity.path)) {
        case FileSystemEntityType.directory:
          await _copySdkDirectory(entity.path, target);
        case FileSystemEntityType.file:
          await File(entity.path).copy(ioPath(target));
        default:
          continue;
      }
    }
  }

  static Future<Directory> _createParentDirectory(String path) =>
      Directory(ioPath(p.dirname(path))).create(recursive: true);

  /// Win32 directory enumeration appends `\\*`, which still hits `MAX_PATH`
  /// unless the absolute path uses the extended-length prefix.
  static String ioPath(String path) {
    if (!Platform.isWindows) return path;
    final absolute = p.absolute(path);
    if (absolute.startsWith(r'\\?\')) return absolute;
    if (absolute.startsWith(r'\\')) {
      return '\\\\?\\UNC\\${absolute.substring(2)}';
    }
    return '\\\\?\\$absolute';
  }

  /// Copy Swift's canonical iPhoneOS layout into its legacy Runtime location.
  static Future<void> materializeSwiftCompatibilityResources(
    String artifactRoot,
  ) async {
    final source = File(
      ioPath(
        p.join(artifactRoot, _swiftResources, 'iphoneos', 'layouts-arm64.yaml'),
      ),
    );
    if (!source.existsSync() || source.lengthSync() == 0) {
      throw XcrossError(
        'Missing or empty canonical Swift iPhoneOS layout: ${source.path}',
      );
    }
    final destination = ioPath(
      p.join(
        artifactRoot,
        'Developer',
        'Runtimes',
        'XcodeDefault.xctoolchain',
        'usr',
        'bin',
        'layouts-arm64.yaml',
      ),
    );
    await Directory(p.dirname(destination)).create(recursive: true);
    await source.copy(destination);
  }

  /// Write the Swift artifact-bundle metadata after extraction.
  static Future<void> writeSwiftSdkBundleMetadata(String artifactRoot) async {
    final sdkRoot = DarwinSdk(artifactRoot).iPhoneOSSdk();
    if (!RegExp('[0-9]').hasMatch(p.basename(sdkRoot))) {
      throw XcrossError(
        'The extracted Xcode archive did not contain a versioned iPhoneOS SDK.',
      );
    }
    // Bundle metadata is always forward-slashed, including on Windows.
    final relativeSdkRoot = p
        .relative(sdkRoot, from: artifactRoot)
        .replaceAll(r'\', '/');

    await _writeJson(p.join(artifactRoot, 'swift-sdk.json'), {
      'schemaVersion': '4.0',
      'targetTriples': {
        'arm64-apple-ios': {
          'sdkRootPath': relativeSdkRoot,
          'swiftResourcesPath': _swiftResources,
          'swiftStaticResourcesPath': _swiftStaticResources,
          'includeSearchPaths': [
            '$_platformDeveloper/usr/lib',
            '$_toolchain/usr/include/c++/v1',
          ],
          'librarySearchPaths': ['$_platformDeveloper/usr/lib'],
          'toolsetPaths': ['toolset.json'],
        },
      },
    });
    await _writeJson(p.join(artifactRoot, 'toolset.json'), const {
      'schemaVersion': '1.0',
      'swiftCompiler': {
        'extraCLIOptions': [
          '-Xfrontend',
          '-enable-cross-import-overlays',
          '-use-ld=lld',
        ],
      },
    });
    await _writeJson(p.join(artifactRoot, 'info.json'), const {
      'schemaVersion': '1.0',
      'artifacts': {
        'xcross-darwin': {
          'type': 'swiftSDK',
          'version': '1.0.0',
          'variants': [
            {
              'path': '.',
              'supportedTriples': [
                'x86_64-unknown-linux-gnu',
                'aarch64-unknown-linux-gnu',
                'x86_64-unknown-windows-msvc',
                'aarch64-unknown-windows-msvc',
              ],
            },
          ],
        },
      },
    });
  }

  static Future<void> _writeJson(String path, Map<String, Object?> value) =>
      File(path).writeAsString('${_json.convert(value)}\n');

  /// Replace Xcode's clang builtin headers with headers matching host Swift.
  static Future<void> replaceClangBuiltinHeaders(
    String artifactRoot, {
    Future<String> Function(String name)? locateTool,
    Future<CapturedProcess> Function(String executable, List<String> arguments)?
    runProcess,
  }) async {
    final (:clang, :swift) = await _swiftSiblingClang(
      locateTool ?? ProcessRunner.locateTool,
    );
    final source = await _clangBuiltinHeaderDir(
      clang,
      swift,
      runProcess ?? ProcessRunner.run,
    );
    final destination = p.join(
      artifactRoot,
      'Developer',
      'Toolchains',
      'XcodeDefault.xctoolchain',
      'usr',
      'lib',
      'swift',
      'clang',
      'include',
    );
    await _deleteAnyEntity(destination);
    await _copySdkDirectory(source, destination);
  }

  /// The clang shipped beside the selected `swift`, which is the one whose
  /// builtin headers match that Swift's module ABI.
  static Future<({String clang, String swift})> _swiftSiblingClang(
    Future<String> Function(String name) locate,
  ) async {
    final String swift;
    try {
      swift = await locate('swift');
    } on Object {
      throw XcrossError(
        'Could not locate the selected Swift executable `swift` on PATH.',
      );
    }

    final String resolvedSwift;
    try {
      resolvedSwift = await File(swift).resolveSymbolicLinks();
    } on Object {
      throw XcrossError(
        'Could not resolve selected Swift executable "$swift".',
      );
    }

    final clang = p.join(
      p.dirname(resolvedSwift),
      ProcessRunner.hostExecutableName('clang'),
    );
    if (!File(clang).existsSync()) {
      throw XcrossError(
        'Selected Swift executable "$resolvedSwift" has no sibling clang at '
        '"$clang".',
      );
    }
    return (clang: clang, swift: resolvedSwift);
  }

  static Future<String> _clangBuiltinHeaderDir(
    String clang,
    String resolvedSwift,
    Future<CapturedProcess> Function(String, List<String>) run,
  ) async {
    final result = await run(clang, const ['-print-resource-dir']);
    final resourceDir = result.stdout.trim();
    final source = p.join(resourceDir, 'include');
    if (result.exitCode != 0 ||
        resourceDir.isEmpty ||
        !Directory(source).existsSync()) {
      final detail = result.stderr.trim();
      final suffix = detail.isEmpty ? '' : '\n$detail';
      throw XcrossError(
        'Could not locate clang builtin headers using sibling clang "$clang" '
        'selected for Swift "$resolvedSwift".$suffix',
      );
    }
    return source;
  }

  /// The destination may be a real directory, a file, or a symlink Xcode
  /// shipped, so delete whichever kind is actually there.
  static Future<void> _deleteAnyEntity(String path) async {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else if (type == FileSystemEntityType.link) {
      await Link(path).delete();
    } else if (type == FileSystemEntityType.file) {
      await File(path).delete();
    }
  }
}

/// cpio writes a hard link's bytes once and leaves later entries for the same
/// `(dev, ino)` empty, so the first payload seen has to be replayed for the
/// rest of the group — even when that first entry is outside the SDK subset.
class _HardLinkPayloads {
  // ponytail: archive-order cache is memory-bound; disk-spool only if a future
  // Xcode archive makes pending groups large.
  final _pending = <(int, int), ({Uint8List data, int remaining})>{};

  Uint8List payloadFor(CpioEntry entry) {
    final fileType = entry.mode & _fileTypeMask;
    final isRegular = fileType == _regularFileType || fileType == 0;
    if (!isRegular || entry.nlink <= 1) return entry.data;

    final key = (entry.dev, entry.ino);
    final group = _pending[key];
    if (group == null) {
      _pending[key] = (data: entry.data, remaining: entry.nlink - 1);
      return entry.data;
    }
    if (group.remaining == 1) {
      _pending.remove(key);
    } else {
      _pending[key] = (data: group.data, remaining: group.remaining - 1);
    }
    return group.data;
  }
}
