import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/response_arguments.dart';
import 'package:xcross/src/shared/flutter/swiftpm/response_file_reader.dart';

const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmPlanReader {
  SwiftPmPlanReader({required this.fileSystem, required this.responseFiles});
  final SwiftPmArtifactFileSystem fileSystem;
  final SwiftPmResponseFileReader responseFiles;
  String resolveTargetBuildDir(
    String scratchPath, {
    String triple = 'arm64-apple-ios',
    String configuration = 'debug',
  }) {
    final candidates = [
      p.join(scratchPath, triple, configuration),
      p.join(scratchPath, 'out', configuration),
    ];
    for (final candidate in candidates) {
      if (fileSystem.file(p.join(candidate, 'description.json')).existsSync()) {
        return candidate;
      }
    }
    for (final candidate in candidates) {
      if (fileSystem.directory(candidate).existsSync()) return candidate;
    }
    return p.join(scratchPath, triple, configuration);
  }

  List<String> plannedSwiftInteropSearchPaths(String targetBuildDir) {
    final description = fileSystem.file(
      p.join(targetBuildDir, 'description.json'),
    );
    try {
      final decoded = jsonDecode(description.readAsStringSync());
      if (decoded is! Map<String, dynamic> ||
          decoded['swiftCommands'] is! Map<String, dynamic>) {
        throw const FormatException('Missing Swift command descriptions');
      }
      final includes = <String>{};
      for (final command
          in (decoded['swiftCommands'] as Map<String, dynamic>).values) {
        if (command is! Map<String, dynamic> ||
            command['otherArguments'] is! List ||
            !(command['otherArguments'] as List).every(
              (argument) => argument is String,
            )) {
          throw const FormatException('Invalid Swift command arguments');
        }
        final arguments = (command['otherArguments'] as List).cast<String>();
        for (var index = 0; index < arguments.length; index++) {
          if (arguments[index] != '-emit-objc-header-path') continue;
          if (++index >= arguments.length) {
            throw const FormatException('Missing generated header path');
          }
          final header = p.normalize(arguments[index]);
          if (!p.isAbsolute(header) ||
              !p.isWithin(p.normalize(p.absolute(targetBuildDir)), header) ||
              !header.endsWith('-Swift.h')) {
            throw const FormatException('Invalid generated header path');
          }
          includes.add(p.dirname(header));
        }
      }
      final sorted = includes.toList()..sort();
      return [
        for (final include in sorted) ...['-Xcc', '-I', '-Xcc', include],
      ];
    } on Object catch (error) {
      throw FlutterBuildError(
        'Cannot read planned Swift interop headers from '
        '${description.path}: $error',
      );
    }
  }

  List<String> plannedSwiftInteropTargets(
    String targetBuildDir, {
    Set<String>? candidates,
  }) {
    final List<String> planned;
    try {
      planned = plannedSwiftInteropSearchPaths(targetBuildDir);
    } on Object {
      return const [];
    }
    final reachable = plannedTargetClosure(targetBuildDir, pluginsProductName);
    final targets = <String>{};
    for (final argument in planned) {
      final directory = p.basename(argument);
      if (directory != 'include') continue;
      final owner = p.basename(p.dirname(argument));
      if (!owner.endsWith('.build')) continue;
      final target = owner.substring(0, owner.length - '.build'.length);
      if (candidates != null && !candidates.contains(target)) {
        continue;
      }
      if (reachable != null && !reachable.contains(target)) continue;
      if (fileSystem.file(p.join(argument, '$target-Swift.h')).existsSync()) {
        continue;
      }
      targets.add(target);
    }
    final sorted = targets.toList()..sort();
    return sorted;
  }

  List<String> orderedInteropTargets(
    String targetBuildDir,
    List<String> planned,
  ) => orderTargetsByDependencies(targetDependencies(targetBuildDir), planned);
  Map<String, dynamic>? targetDependencies(String targetBuildDir) {
    try {
      final decoded = jsonDecode(
        fileSystem
            .file(p.join(targetBuildDir, 'description.json'))
            .readAsStringSync(),
      );
      return decoded is Map<String, dynamic>
          ? decoded['targetDependencyMap'] as Map<String, dynamic>?
          : null;
    } on Object {
      return null;
    }
  }

  static List<String> orderTargetsByDependencies(
    Map<String, dynamic>? dependencies,
    List<String> planned,
  ) {
    final eligible = planned.toSet()..remove(pluginsProductName);
    final ordered = <String>[];
    final visited = <String>{};
    final visiting = <String>{};

    void visit(String target) {
      if (!eligible.contains(target) || visited.contains(target)) return;
      if (!visiting.add(target)) {
        throw FlutterBuildError(
          'SwiftPM interop target dependency cycle at $target',
        );
      }
      final children = dependencies?[target];
      if (children is List) {
        for (final dependency in children.whereType<String>()) {
          visit(dependency);
        }
      }
      visiting.remove(target);
      visited.add(target);
      ordered.add(target);
    }

    for (final target in planned) {
      visit(target);
    }
    return ordered;
  }

  Set<String>? plannedTargetClosure(String targetBuildDir, String root) {
    final description = fileSystem.file(
      p.join(targetBuildDir, 'description.json'),
    );
    final Map<String, List<String>> edges;
    try {
      final decoded = jsonDecode(description.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return null;
      final map = decoded['targetDependencyMap'];
      if (map is! Map<String, dynamic>) return null;
      edges = {
        for (final entry in map.entries)
          if (entry.value case final List<dynamic> dependencies)
            entry.key: [
              for (final dependency in dependencies)
                if (dependency is String) dependency,
            ],
      };
    } on Object {
      return null;
    }
    if (edges.isEmpty) return null;
    final seen = <String>{root};
    final stack = <String>[root];
    while (stack.isNotEmpty) {
      for (final next in edges[stack.removeLast()] ?? const <String>[]) {
        if (seen.add(next)) stack.add(next);
      }
    }
    return seen;
  }

  bool manifestCarriesInteropSearchPaths(
    String scratchPath,
    List<String> interopArguments,
  ) {
    final manifest = fileSystem.file(p.join(scratchPath, 'debug.yaml'));
    final String text;
    try {
      text = manifest.readAsStringSync();
    } on Object {
      return false;
    }
    if (text.isEmpty) return false;
    final responseArguments = responseFiles.referencedResponseArguments(
      text,
      scratchPath,
    );
    if (responseArguments == null) return false;
    bool recorded(String path) =>
        text.contains(jsonEncode(path)) ||
        responseArguments.contains(
          SwiftPmResponseArguments.quoteWindowsArgument(path),
        ) ||
        responseArguments.contains(
          SwiftPmResponseArguments.quoteGnuArgument(path),
        );
    var checked = 0;
    for (var index = 0; index + 2 < interopArguments.length; index++) {
      if (interopArguments[index] != '-I') continue;
      if (interopArguments[index + 1] != '-Xcc') continue;
      checked++;
      if (!recorded(interopArguments[index + 2])) return false;
    }
    return checked > 0;
  }

  List<String> swiftInteropSearchPaths(String targetBuildDir) {
    final directory = fileSystem.directory(targetBuildDir);
    if (!directory.existsSync()) return const [];
    final includes = <String>[];
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (!name.endsWith('.build')) continue;
      final include = p.join(entity.path, 'include');
      final module = name.substring(0, name.length - '.build'.length);
      if (fileSystem.file(p.join(include, '$module-Swift.h')).existsSync()) {
        includes.add(include);
      }
    }
    includes.sort();
    return [
      for (final include in includes) ...['-Xcc', '-I', '-Xcc', include],
    ];
  }
}
