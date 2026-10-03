import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';

import 'declarations.dart';
import 'export_graph.dart';
import 'identity.dart';
import 'inventory.dart';
import 'rules.dart';
import 'workspace_inventory.dart';

export 'inventory.dart';

Future<List<Violation>> inspectFiles(String root, List<String> paths) async {
  final collection = AnalysisContextCollection(includedPaths: [root]);
  final violations = <Violation>[];
  final units = <String, CompilationUnit>{};
  try {
    for (final path in paths) {
      final absolute = '$root/$path';
      if (!path.endsWith('.dart')) {
        if (classify(path).kind == 'unclassified') {
          violations.add(
            Violation(path, 'inventory', 0, 'Unclassified production asset'),
          );
        }
        continue;
      }
      final contexts =
          collection.contexts
              .where((c) => absolute.startsWith('${c.contextRoot.root.path}/'))
              .toList()
            ..sort(
              (a, b) => b.contextRoot.root.path.length.compareTo(
                a.contextRoot.root.path.length,
              ),
            );
      if (contexts.isEmpty) {
        violations.add(Violation(path, 'resolution', 0, 'No analysis context'));
        continue;
      }
      final result = await contexts.first.currentSession.getResolvedUnit(
        absolute,
      );
      if (result is! ResolvedUnitResult) {
        violations.add(
          Violation(path, 'resolution', 0, 'Cannot resolve production source'),
        );
        continue;
      }
      units[path] = result.unit;
    }
    final exports = ExportGraph(units);
    final identity = IdentityAnalysis();
    for (;;) {
      final count = identity.aliases.values.fold<int>(
        0,
        (sum, kinds) => sum + kinds.length,
      );
      for (final entry in units.entries) {
        identity.discover(entry.value);
      }
      if (count ==
          identity.aliases.values.fold<int>(
            0,
            (sum, kinds) => sum + kinds.length,
          )) {
        break;
      }
    }
    for (final entry in units.entries) {
      if (classify(entry.key).kind == 'test') {
        final rules = DeclarationRules(entry.key);
        entry.value.accept(rules);
        violations.addAll(rules.violations);
      } else {
        violations.addAll(
          Guard(entry.key, identity, exports).inspect(entry.value),
        );
      }
    }
  } finally {
    await collection.dispose();
  }
  return violations;
}

bool production(String path) {
  final parts = path.split('/');
  if (path.startsWith('.github/')) return true;
  if (path.startsWith('tool/')) return true;
  if (!path.startsWith('packages/') ||
      parts.length < 4 ||
      !workspacePackages.contains(parts[1])) {
    return false;
  }
  return {'lib', 'bin', 'hook', 'src', 'native', 'tool'}.contains(parts[2]);
}

Future<void> main(List<String> args) async {
  if (args.any((a) => a != '--report')) {
    throw ArgumentError('Supported option: --report');
  }
  final root = Directory.current.absolute.path;
  final files = await Process.run('git', [
    'ls-files',
    '-z',
    '--cached',
    '--others',
    '--exclude-standard',
  ], workingDirectory: root);
  if (files.exitCode != 0) {
    throw StateError('Cannot inventory repository: ${files.stderr}');
  }
  final rawPaths = (files.stdout as String).split('\u0000');
  final paths =
      rawPaths
          .where(
            (p) =>
                production(p) ||
                p.startsWith('packages/') &&
                    p.split('/').length > 2 &&
                    workspacePackages.contains(p.split('/')[1]) &&
                    p.split('/')[2] == 'test' &&
                    p.endsWith('.dart'),
          )
          .where((p) => File('$root/$p').existsSync())
          .toSet()
          .toList()
        ..sort();
  final violations = [
    ...workspaceViolations(
      File('$root/pubspec.yaml').readAsStringSync(),
      rawPaths,
    ),
    ...await inspectFiles(root, paths),
  ];
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'mode': args.contains('--report') ? 'migration' : 'final',
      'inventory': {for (final path in paths) path: classify(path).toJson()},
      'violations': violations.map((v) => v.toJson()).toList(),
    }),
  );
  if (violations.isNotEmpty && !args.contains('--report')) exitCode = 1;
}
