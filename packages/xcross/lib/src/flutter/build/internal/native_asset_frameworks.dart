import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/flutter/build/macho_dylib_rewriter.dart';
import 'package:xcross/src/flutter/build/macho_linkedit_aligner.dart';
import 'package:xcross/src/flutter/errors.dart';

const _fatMachOMagics = <int>{
  0xcafebabe, // FAT_MAGIC
  0xbebafeca, // FAT_CIGAM
  0xcafebabf, // FAT_MAGIC_64
  0xbfbafeca, // FAT_CIGAM_64
};

List<String> collectNativeAssetFrameworks(
  String manifest,
  String outputDirectory, {
  String? projectRoot,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(manifest);
  } on FormatException catch (error) {
    throw FlutterBuildError('Invalid native assets manifest: $error');
  }
  if (decoded is! Map<String, dynamic> ||
      decoded['native-assets'] is! Map<String, dynamic>) {
    throw FlutterBuildError(
      'Invalid native assets manifest: missing native-assets',
    );
  }
  final targets = decoded['native-assets'] as Map<String, dynamic>;
  final assets = targets['ios_arm64'];
  if (assets == null) return const [];
  if (assets is! Map<String, dynamic>) {
    throw FlutterBuildError(
      'Invalid native assets manifest: ios_arm64 is not a map',
    );
  }
  final directories = <Directory>[
    Directory(p.join(outputDirectory, 'native_assets')),
    if (projectRoot != null)
      Directory(p.join(projectRoot, 'build', 'native_assets', 'ios')),
  ];
  final frameworks = <String, String>{};
  for (final asset in assets.values) {
    if (asset is! List || asset.length < 2 || asset[1] is! String) continue;
    if (asset[0] != 'absolute' && asset[0] != 'relative') continue;
    final path = (asset[1] as String).replaceAll(r'\', '/');
    final component = path
        .split('/')
        .lastIndexWhere((part) => part.endsWith('.framework'));
    if (component < 0) continue;
    final frameworkPath = path.split('/').take(component + 1).join('/');
    final candidates = p.isAbsolute(frameworkPath)
        ? [frameworkPath]
        : [
            for (final directory in directories)
              p.normalize(p.join(directory.path, frameworkPath)),
          ];
    final found = candidates
        .where((path) => Directory(path).existsSync())
        .toList();
    if (found.isEmpty) {
      throw FlutterBuildError(
        'Native asset framework not found: $frameworkPath',
      );
    }
    // The active assemble output precedes the package-local fallback. A
    // previous build may leave the same framework in both locations; choose
    // one source now and carry that exact path through repair and embedding.
    final selected = found.first;
    final name = p.basename(selected);
    final previous = frameworks[name];
    if (previous != null && !p.equals(previous, selected)) {
      throw FlutterBuildError('Native asset framework name collision: $name');
    }
    frameworks[name] = selected;
  }
  return frameworks.values.toList();
}

/// Makes disposable copies before thinning and repairing Flutter-owned outputs.
///
/// Every symlink is checked first: repairs write through staged links, so a
/// link that escapes its framework would let them modify the original hook
/// output, and a bundled link would carry a host path onto the device.
Future<List<String>> stageNativeAssetFrameworks(
  Iterable<String> sources,
  String outputDirectory,
) async {
  final checkedSources = sources.toList();
  for (final source in checkedSources) {
    await _validateFrameworkLinks(source);
  }
  final stage = Directory(p.join(outputDirectory, 'xcross_staged_frameworks'));
  if (stage.existsSync()) await stage.delete(recursive: true);
  await stage.create(recursive: true);
  final frameworks = <String>[];
  for (final source in checkedSources) {
    final destination = p.join(stage.path, p.basename(source));
    await copyDirectoryPreservingSymlinks(source, destination);
    frameworks.add(destination);
  }
  return frameworks;
}

/// Relative links are portable only when both their spelled and fully resolved
/// targets stay inside this framework. In particular, resolving a link chain
/// must not hide an escape through a directory symlink.
Future<void> _validateFrameworkLinks(String source) async {
  final root = await Directory(source).resolveSymbolicLinks();
  await for (final entity in Directory(
    root,
  ).list(recursive: true, followLinks: false)) {
    if (entity is! Link) continue;
    final target = await entity.target();
    final localTarget = p.normalize(p.join(p.dirname(entity.path), target));
    String? resolved;
    try {
      resolved = await entity.resolveSymbolicLinks();
    } on FileSystemException {
      // Dangling links and cycles cannot be proven safe to repair or bundle.
    }
    if (p.isAbsolute(target) ||
        !p.isWithin(root, localTarget) ||
        resolved == null ||
        !p.isWithin(root, resolved)) {
      throw FlutterBuildError(
        'Unsafe native asset framework symlink: ${entity.path} -> $target. '
        'Only resolvable framework-relative links within the same framework '
        'can be staged safely.',
      );
    }
  }
}

Future<bool> isFatMachO(String path) async {
  final file = File(path);
  if (!file.existsSync() || await file.length() < 4) return false;
  final bytes = await file.openRead(0, 4).expand((chunk) => chunk).toList();
  final magic = ByteData.sublistView(Uint8List.fromList(bytes)).getUint32(0);
  return _fatMachOMagics.contains(magic);
}

/// Repairs native-asset binaries whose LINKEDIT string table `ld64.lld`
/// left 4-byte aligned, which dyld on iOS 26 refuses to load.
///
/// Runs over every framework because any of them can carry the layout that
/// triggers it (an odd indirect-symbol count); binaries that are already
/// aligned are left untouched.
Future<void> alignNativeAssetLinkedit(Iterable<String> frameworks) async {
  for (final framework in frameworks) {
    final binary = p.join(framework, p.basenameWithoutExtension(framework));
    if (await MachOLinkeditAligner.alignFile(binary)) {
      Log.logTrace('realigned LINKEDIT string table in $binary');
    }
  }
}

Future<void> normalizeNativeAssetInstallNames(
  Iterable<String> frameworks,
) async {
  final installNames = <String, String>{};
  final binaries = <String, String>{};
  for (final framework in frameworks) {
    final name = p.basenameWithoutExtension(framework);
    final binary = p.join(framework, name);
    binaries[name] = binary;
    final installName = '@rpath/$name.framework/$name';
    installNames[name] = installName;
    installNames['$name.dylib'] = installName;
    installNames['lib$name.dylib'] = installName;
  }
  for (final entry in binaries.entries) {
    await MachODylibRewriter.rewriteFile(
      entry.value,
      producedDylibNames: const {},
      installName: installNames[entry.key],

      producedInstallNames: installNames,
    );
  }
}

Future<void> thinFrameworksToArm64(
  Iterable<String> frameworks, {
  required String lipo,
}) async {
  for (final framework in frameworks) {
    final binary = p.join(framework, p.basenameWithoutExtension(framework));
    if (!await isFatMachO(binary)) continue;

    final thin = '$binary.xcross-thin';
    try {
      await ProcessRunner.runChecked(lipo, [
        '-thin',
        'arm64',
        binary,
        '-output',
        thin,
      ], label: 'llvm-lipo');
      // File.rename cannot replace an existing file on Windows. copy() can,
      // and keeps the original intact until lipo has completed successfully.
      await File(thin).copy(binary);
    } finally {
      final temporary = File(thin);
      if (temporary.existsSync()) await temporary.delete();
    }
  }
}
