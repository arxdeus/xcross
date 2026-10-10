import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';

/// Name of the generated target that pre-builds the implicit Clang modules
/// every plugin imports.
@internal
const String moduleWarmupTargetName = 'XcrossModuleWarmup';

/// Pre-builds the SDK's implicit Clang modules in a single compiler process.
///
/// Windows builds run without Clang's implicit module locks, which deadlock
/// there (see `SwiftPmBuildPlan.noImplicitModuleLockArguments`). Without the
/// lock, every parallel frontend that imports `UIKit` builds `UIKit.pcm` and
/// its whole closure (`CoreImage`, `ImageIO`, ...) itself, into the same
/// module cache. On Windows the loser of that race cannot replace a `.pcm`
/// the winner still holds open ("unable to open output file ... .pcm:
/// operation not permitted"), or sees the same module twice ("module 'UIKit'
/// is defined in both X and X").
///
/// Building one target that imports every SDK module the plugins use, before
/// the parallel build starts, leaves each `.pcm` already in the cache. The
/// parallel frontends then only read them, so there is nothing left to race
/// on.
@internal
final class SwiftPmModuleWarmup {
  SwiftPmModuleWarmup({required this.fileSystem});
  final SwiftPmArtifactFileSystem fileSystem;

  /// Swift settings for the warm-up target. Whole-module mode with the module
  /// emitted in the same job keeps the target to exactly one frontend, so it
  /// cannot race with itself.
  static const List<String> swiftFlags = [
    '-wmo',
    '-no-emit-module-separately-wmo',
  ];

  /// Source directory of the warm-up target inside the plugins package.
  static String sourcesDir(String pluginsDir) =>
      p.join(pluginsDir, 'Sources', moduleWarmupTargetName);

  /// Source file of the warm-up target inside the plugins package.
  static String sourceFile(String pluginsDir) =>
      p.join(sourcesDir(pluginsDir), 'Warmup.swift');

  /// Modules every Flutter iOS plugin pulls in. Seeds the target before the
  /// plugin graph is resolved, and stays in the list afterwards.
  static const List<String> baselineModules = [
    'Flutter',
    'Foundation',
    'UIKit',
  ];

  /// Rewrites the warm-up source to import every SDK module used under
  /// [roots]. A content-stable write, so an unchanged module list does not
  /// invalidate anything.
  Future<List<String>> refresh({
    required String pluginsDir,
    required List<String> roots,
    required String iosSdk,
    required Future<void> Function(String path, String content) write,
  }) async {
    final modules = await sdkModules(roots: roots, iosSdk: iosSdk);
    await write(sourceFile(pluginsDir), source(modules));
    return modules;
  }

  static final RegExp _swiftImport = RegExp(
    r'^[ \t]*(?:@[A-Za-z_]\w*(?:\([^)\n]*\))?[ \t]+)*import[ \t]+'
    r'(?:(?:class|struct|enum|protocol|func|var|let|typealias)[ \t]+)?'
    r'([A-Za-z_]\w*)',
    multiLine: true,
  );
  static final RegExp _objectiveCModuleImport = RegExp(
    r'@import[ \t]+([A-Za-z_]\w*)',
  );
  static final RegExp _objectiveCFrameworkInclude = RegExp(
    r'^[ \t]*#[ \t]*(?:import|include)[ \t]*<([A-Za-z_]\w*)/',
    multiLine: true,
  );
  static const Set<String> _sourceExtensions = {'.swift', '.h', '.m', '.mm'};

  /// Directories whose sources never reach the plugin build. Scanning them
  /// would only warm modules nothing imports.
  static const Set<String> _skippedDirectories = {
    '.git',
    '.build',
    'Tests',
    'Example',
    'Examples',
  };

  /// Module names imported by [source], in the order they appear.
  static Iterable<String> importedModules(String source) sync* {
    for (final pattern in [
      _swiftImport,
      _objectiveCModuleImport,
      _objectiveCFrameworkInclude,
    ]) {
      for (final match in pattern.allMatches(source)) {
        yield match[1]!;
      }
    }
  }

  /// The SDK frameworks imported anywhere under [roots], plus
  /// [baselineModules].
  ///
  /// Only names that exist as a framework in [iosSdk] are kept: plugin
  /// modules are built by their own targets and must not be warmed here.
  Future<List<String>> sdkModules({
    required List<String> roots,
    required String iosSdk,
  }) async {
    final frameworks = p.join(iosSdk, 'System', 'Library', 'Frameworks');
    final known = <String, bool>{};
    bool isSdkFramework(String name) => known.putIfAbsent(
      name,
      () => fileSystem
          .directory(p.join(frameworks, '$name.framework'))
          .existsSync(),
    );
    final modules = <String>{...baselineModules};
    for (final root in roots) {
      await for (final file in _sources(root)) {
        final String source;
        try {
          source = await file.readAsString();
        } on Object {
          continue;
        }
        for (final name in importedModules(source)) {
          if (isSdkFramework(name)) modules.add(name);
        }
      }
    }
    return modules.toList()..sort();
  }

  Stream<File> _sources(String root) async* {
    final directory = fileSystem.directory(root);
    if (!directory.existsSync()) return;
    final pending = <Directory>[directory];
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      final String identity;
      try {
        identity = current.resolveSymbolicLinksSync();
      } on Object {
        continue;
      }
      if (!visited.add(identity)) continue;
      final List<FileSystemEntity> entries;
      try {
        entries = current.listSync();
      } on Object {
        continue;
      }
      for (final entry in entries) {
        final name = p.basename(entry.path);
        if (entry is Directory) {
          if (!_skippedDirectories.contains(name)) pending.add(entry);
        } else if (entry is File &&
            _sourceExtensions.contains(p.extension(name))) {
          yield entry;
        }
      }
    }
  }

  /// Swift source importing each of [modules] that the compiler can find.
  ///
  /// `canImport` keeps a framework unavailable for the target (or a name the
  /// scan misread) from failing the whole warm-up.
  static String source(List<String> modules) {
    final buffer = StringBuffer()
      ..writeln('//')
      ..writeln('// Generated file. Do not edit.')
      ..writeln('//')
      ..writeln(
        '// Imports every SDK module the plugins use, so their implicit',
      )
      ..writeln('// Clang modules are built once, in one compiler process,')
      ..writeln('// before the parallel plugin build reads them.')
      ..writeln('//');
    for (final module in modules) {
      buffer
        ..writeln('#if canImport($module)')
        ..writeln('import $module')
        ..writeln('#endif');
    }
    return buffer.toString();
  }
}
