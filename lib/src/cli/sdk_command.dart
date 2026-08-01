import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import 'package:xcross/src/darwinsdk/cpio_reader.dart';
import 'package:xcross/src/darwinsdk/darwin_sdk.dart';
import 'package:xcross/src/darwinsdk/xcode_xip_extractor.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';

/// `xcross sdk` — manage xcross's host-neutral Darwin Swift SDK.
class SdkCommand extends Command<void> {
  SdkCommand() {
    addSubcommand(SdkInstallCommand());
  }

  @override
  String get name => 'sdk';

  @override
  String get description => 'Manage the xcross Darwin Swift SDK.';
}

/// The iOS subset required by Swift's Linux cross-SDK protocol.
const sdkIncludedRoots = <String>[
  'Developer/Platforms/iPhoneOS.platform/Developer/SDKs',
  'Developer/Platforms/iPhoneOS.platform/Developer/Library/Frameworks',
  'Developer/Platforms/iPhoneOS.platform/Developer/Library/PrivateFrameworks',
  'Developer/Platforms/iPhoneOS.platform/Developer/usr/lib',
  'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift',
  'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift_static',
  'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang',
];

/// Destination-relative path for an included cpio entry, or null when the
/// entry is outside [sdkIncludedRoots].
String? sdkRelativePath(String name) {
  final archiveName = name.replaceAll(r'\', '/');
  for (final root in sdkIncludedRoots) {
    if (archiveName == root || archiveName.startsWith('$root/')) {
      return archiveName;
    }
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

const _fileTypeMask = 0xF000;
const _directoryType = 0x4000;
const _regularFileType = 0x8000;
const _symbolicLinkType = 0xA000;

Future<int> writeSdkEntries(
  Stream<CpioEntry> entries,
  String destDir, {
  bool? materializeLinks,
  void Function(int count)? onProgress,
}) async {
  final root = p.normalize(p.absolute(destDir));
  await Directory(root).create(recursive: true);
  final links = <String, String>{};
  var written = 0;

  await for (final entry in entries) {
    final archivePath = sdkRelativePath(entry.name);
    if (archivePath == null) continue;
    if (archivePath.split('/').contains('..')) {
      throw XcrossError('Unsafe SDK archive path: ${entry.name}');
    }
    final relative = p.normalize(archivePath.replaceAll('/', p.separator));
    final destPath = p.normalize(p.join(root, relative));
    if (p.isAbsolute(relative) || !p.isWithin(root, destPath)) {
      throw XcrossError('Unsafe SDK archive path: ${entry.name}');
    }

    switch (entry.mode & _fileTypeMask) {
      case _directoryType:
        await Directory(destPath).create(recursive: true);
      case _symbolicLinkType:
        await Directory(p.dirname(destPath)).create(recursive: true);
        links[destPath] = utf8.decode(entry.data);
      case _regularFileType || 0:
        await Directory(p.dirname(destPath)).create(recursive: true);
        await File(destPath).writeAsBytes(entry.data);
        if (entry.mode & 0x49 != 0) ProcessRunner.makeExecutable(destPath);
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

Future<void> _materializeSdkLinks(
  String root,
  Map<String, String> links,
) async {
  final pending = Map<String, String>.from(links);
  while (pending.isNotEmpty) {
    var progressed = false;
    for (final link in pending.entries.toList()) {
      final target = _resolvedSdkLinkTarget(root, link.key, link.value);
      final type = FileSystemEntity.typeSync(target);
      if (type == FileSystemEntityType.notFound) continue;
      if (type == FileSystemEntityType.directory &&
          pending.keys.any(
            (other) => other != link.key && p.isWithin(target, other),
          )) {
        continue;
      }

      if (type == FileSystemEntityType.directory) {
        await _copySdkDirectory(target, link.key);
      } else if (type == FileSystemEntityType.file) {
        await File(target).copy(link.key);
      } else {
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

String _resolvedSdkLinkTarget(String root, String link, String rawTarget) {
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

Future<void> _copySdkDirectory(String source, String destination) async {
  await Directory(destination).create(recursive: true);
  await for (final entity in Directory(source).list()) {
    final target = p.join(destination, p.basename(entity.path));
    final type = FileSystemEntity.typeSync(entity.path);
    if (type == FileSystemEntityType.directory) {
      await _copySdkDirectory(entity.path, target);
    } else if (type == FileSystemEntityType.file) {
      await File(entity.path).copy(target);
    }
  }
}

const _platformDeveloper = 'Developer/Platforms/iPhoneOS.platform/Developer';
const _toolchainLib = 'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib';
const _swiftResources = '$_toolchainLib/swift';
const _swiftStaticResources = '$_toolchainLib/swift_static';

/// Write the Swift artifact-bundle metadata after extraction.
Future<void> writeSwiftSdkBundleMetadata(String artifactRoot) async {
  final sdkRoot = DarwinSdk(artifactRoot).iPhoneOSSdk();
  if (!RegExp('[0-9]').hasMatch(p.basename(sdkRoot))) {
    throw XcrossError(
      'The extracted Xcode archive did not contain a versioned iPhoneOS SDK.',
    );
  }
  final relativeSdkRoot = _metadataPath(
    p.relative(sdkRoot, from: artifactRoot),
  );

  const encoder = JsonEncoder.withIndent('  ');
  await File(p.join(artifactRoot, 'swift-sdk.json')).writeAsString(
    '${encoder.convert({
      'schemaVersion': '4.0',
      'targetTriples': {
        'arm64-apple-ios': {
          'sdkRootPath': relativeSdkRoot,
          'swiftResourcesPath': _swiftResources,
          'swiftStaticResourcesPath': _swiftStaticResources,
          'includeSearchPaths': ['$_platformDeveloper/usr/lib'],
          'librarySearchPaths': ['$_platformDeveloper/usr/lib', '$_swiftResources/iphoneos', '$_swiftStaticResources/iphoneos'],
          'toolsetPaths': ['toolset.json'],
        },
      },
    })}\n',
  );
  await File(p.join(artifactRoot, 'toolset.json')).writeAsString(
    '${encoder.convert({
      'schemaVersion': '1.0',
      'swiftCompiler': {
        'extraCLIOptions': ['-Xfrontend', '-enable-cross-import-overlays', '-use-ld=lld'],
      },
    })}\n',
  );
  await File(p.join(artifactRoot, 'info.json')).writeAsString(
    '${encoder.convert({
      'schemaVersion': '1.0',
      'artifacts': {
        'xcross-darwin': {
          'type': 'swiftSDK',
          'version': '1.0.0',
          'variants': [
            {
              'path': '.',
              'supportedTriples': ['x86_64-unknown-linux-gnu', 'aarch64-unknown-linux-gnu', 'x86_64-unknown-windows-msvc', 'aarch64-unknown-windows-msvc'],
            },
          ],
        },
      },
    })}\n',
  );
}

String _metadataPath(String path) => path.replaceAll(r'\', '/');

/// Replace Xcode's clang builtin headers with headers matching the host clang.
Future<void> replaceClangBuiltinHeaders(String artifactRoot) async {
  String clang;
  try {
    clang = await ProcessRunner.locateTool('clang');
  } on Object {
    throw XcrossError(
      'clang is required to install the Darwin Swift SDK. Install LLVM clang '
      'and ensure `clang` is on PATH, then retry.',
    );
  }

  final result = await ProcessRunner.run(clang, const ['-print-resource-dir']);
  final resourceDir = result.stdout.trim();
  final source = p.join(resourceDir, 'include');
  if (result.exitCode != 0 ||
      resourceDir.isEmpty ||
      !Directory(source).existsSync()) {
    final detail = result.stderr.trim();
    throw XcrossError(
      'Could not locate clang builtin headers with '
      '`clang -print-resource-dir`. Verify the LLVM clang installation and '
      'retry.${detail.isEmpty ? '' : '\n$detail'}',
    );
  }

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
  final existingType = FileSystemEntity.typeSync(
    destination,
    followLinks: false,
  );
  if (existingType == FileSystemEntityType.directory) {
    await Directory(destination).delete(recursive: true);
  } else if (existingType == FileSystemEntityType.link) {
    await Link(destination).delete();
  } else if (existingType == FileSystemEntityType.file) {
    await File(destination).delete();
  }
  await _copySdkDirectory(source, destination);
}

/// `xcross sdk install <Xcode.xip>` — build xcross's Darwin Swift SDK bundle.
class SdkInstallCommand extends Command<void> {
  @override
  String get name => 'install';

  @override
  String get description =>
      'Extract a host-neutral Darwin Swift SDK from an Xcode.xip.';

  @override
  String get invocation => 'xcross sdk install <path-to-Xcode.xip>';

  static const _progressInterval = 250;

  @override
  Future<void> run() async {
    final xipPath = argResults!.rest.firstOrNull;
    if (xipPath == null) throw XcrossError('Usage: $invocation');
    if (!File(xipPath).existsSync()) {
      throw XcrossError('No file found at "$xipPath".');
    }

    final destDir = DarwinSdk.nativeInstallDir();
    if (Directory(destDir).existsSync()) {
      await Directory(destDir).delete(recursive: true);
    }
    final written = await _extract(xipPath, destDir);
    if (written == 0) {
      throw XcrossError(
        '$xipPath: extraction produced no files from the required iOS SDK '
        'subset. Verify that this is a complete Xcode.xip.',
      );
    }

    await replaceClangBuiltinHeaders(destDir);
    await writeSwiftSdkBundleMetadata(destDir);
    Log.logDone('Installed Darwin Swift SDK ($written entries) at $destDir');
  }

  Future<int> _extract(String xipPath, String destDir) async {
    final step = Log.beginStep('Extracting Darwin Swift SDK from Xcode.xip');
    try {
      final written = await writeSdkEntries(
        extractXcodeXipContent(xipPath),
        destDir,
        onProgress: (count) {
          if (count % _progressInterval == 0) {
            step.log('$count entries extracted…\n');
          }
        },
      );
      step.done('Extracted $written entries');
      return written;
    } on Object {
      step.fail();
      rethrow;
    }
  }
}
