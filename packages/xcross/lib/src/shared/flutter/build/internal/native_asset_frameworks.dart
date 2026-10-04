import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/internal/native_asset_linkage.dart';
import 'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/shared/flutter/build/macho_dylib_rewriter.dart';
import 'package:xcross/src/shared/flutter/build/macho_linkedit_aligner.dart';
import 'package:xcross/src/shared/flutter/errors.dart';

const _fatMachOMagics = <int>{
  0xcafebabe, // FAT_MAGIC
  0xbebafeca, // FAT_CIGAM
  0xcafebabf, // FAT_MAGIC_64
  0xbfbafeca, // FAT_CIGAM_64
};

final class NativeAssetFrameworks<T extends PlatformHostInterface> {
  NativeAssetFrameworks({
    required this.fileSystem,
    required this.paths,
    required this.runner,
    required this.copier,
  }) {
    if (!identical(fileSystem, runner.host.fileSystem) ||
        !identical(paths, runner.host.paths.context) ||
        !identical(fileSystem, copier.fileSystem) ||
        !identical(paths, copier.paths)) {
      throw ArgumentError(
        'Native framework collaborators must share selected ports',
      );
    }
  }

  final HostFileSystemInterface fileSystem;
  final p.Context paths;
  final ProcessRunner<T> runner;
  final RecursiveDirectoryCopier copier;
  late final NativeAssetLinkage _linkage = NativeAssetLinkage(
    fileSystem: fileSystem,
    paths: paths,
  );

  Future<List<String>> requiredByPlugins(
    Iterable<String> frameworks,
    Iterable<String> pluginLibraries,
  ) => _linkage.requiredByPlugins(frameworks, pluginLibraries);

  List<String> collect(
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
    final directories = <String>[
      paths.join(outputDirectory, 'native_assets'),
      if (projectRoot != null)
        paths.join(projectRoot, 'build', 'native_assets', 'ios'),
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
      final candidates = paths.isAbsolute(frameworkPath)
          ? [frameworkPath]
          : [
              for (final directory in directories)
                paths.normalize(paths.join(directory, frameworkPath)),
            ];
      final found = candidates
          .where((path) => fileSystem.directory(path).existsSync())
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
      final name = paths.basename(selected);
      final previous = frameworks[name];
      if (previous != null && !paths.equals(previous, selected)) {
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
  Future<List<String>> stage(
    Iterable<String> sources,
    String outputDirectory,
  ) async {
    final checkedSources = sources.toList();
    for (final source in checkedSources) {
      await _validateFrameworkLinks(source);
    }
    final stagePath = paths.join(outputDirectory, 'xcross_staged_frameworks');
    final stage = fileSystem.directory(stagePath);
    if (stage.existsSync()) await stage.delete(recursive: true);
    await stage.create(recursive: true);
    final frameworks = <String>[];
    for (final source in checkedSources) {
      final destination = paths.join(stagePath, paths.basename(source));
      await copier.copy(source, destination);
      frameworks.add(destination);
    }
    return frameworks;
  }

  /// Relative links are portable only when both their spelled and fully resolved
  /// targets stay inside this framework. In particular, resolving a link chain
  /// must not hide an escape through a directory symlink.
  Future<void> _validateFrameworkLinks(String source) async {
    final directory = fileSystem.directory(source);
    final lexicalRoot = paths.normalize(directory.path);
    final root = await directory.resolveSymbolicLinks();
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! Link) continue;
      final target = await entity.target();
      final localTarget = paths.normalize(
        paths.join(paths.dirname(entity.path), target),
      );
      String? resolved;
      try {
        resolved = await entity.resolveSymbolicLinks();
      } on FileSystemException {
        // Dangling links and cycles cannot be proven safe to repair or bundle.
      }
      if (paths.isAbsolute(target) ||
          !paths.isWithin(lexicalRoot, localTarget) ||
          resolved == null ||
          !paths.isWithin(root, resolved)) {
        throw FlutterBuildError(
          'Unsafe native asset framework symlink: ${entity.path} -> $target. '
          'Only resolvable framework-relative links within the same framework '
          'can be staged safely.',
        );
      }
    }
  }

  Future<bool> isFat(String path) async {
    final file = fileSystem.file(path);
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
  Future<void> align(Iterable<String> frameworks) async {
    for (final framework in frameworks) {
      final binary = paths.join(
        framework,
        paths.basenameWithoutExtension(framework),
      );
      final file = fileSystem.file(binary);
      if (!file.existsSync()) continue;
      final bytes = await file.readAsBytes();
      if (MachOLinkeditAligner.alignBytes(bytes, source: binary)) {
        await file.writeAsBytes(bytes, flush: true);
        runner.log.logTrace('realigned LINKEDIT string table in $binary');
      }
    }
  }

  Future<void> normalize(Iterable<String> frameworks) async {
    final installNames = <String, String>{};
    final binaries = <String, String>{};
    for (final framework in frameworks) {
      final name = paths.basenameWithoutExtension(framework);
      final binary = paths.join(framework, name);
      binaries[name] = binary;
      final installName = '@rpath/$name.framework/$name';
      installNames[name] = installName;
      installNames['$name.dylib'] = installName;
      installNames['lib$name.dylib'] = installName;
    }
    for (final entry in binaries.entries) {
      final file = fileSystem.file(entry.value);
      final bytes = await file.readAsBytes();
      final changed = MachODylibRewriter.rewriteBytes(
        bytes,
        dylibName: paths.basename(entry.value),
        producedDylibNames: const {},
        installName: installNames[entry.key],

        producedInstallNames: installNames,
        source: entry.value,
      );
      if (changed) await file.writeAsBytes(bytes, flush: true);
    }
  }

  Future<void> thin(Iterable<String> frameworks, {required String lipo}) async {
    for (final framework in frameworks) {
      final binary = paths.join(
        framework,
        paths.basenameWithoutExtension(framework),
      );
      if (!await isFat(binary)) continue;

      final thin = '$binary.xcross-thin';
      try {
        await runner.runChecked(lipo, [
          '-thin',
          'arm64',
          binary,
          '-output',
          thin,
        ], label: 'llvm-lipo');
        // File.rename cannot replace an existing file on Windows. copy() can,
        // and keeps the original intact until lipo has completed successfully.
        await fileSystem.file(thin).copy(fileSystem.file(binary).path);
      } finally {
        final temporary = fileSystem.file(thin);
        if (temporary.existsSync()) await temporary.delete();
      }
    }
  }
}
