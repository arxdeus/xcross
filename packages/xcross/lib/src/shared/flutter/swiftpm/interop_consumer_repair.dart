import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/plan_reader.dart'
    as swiftpm_plan_reader;

@internal
final class SwiftPmInteropConsumerRepair<T extends PlatformHostInterface> {
  SwiftPmInteropConsumerRepair({
    required this.filesystem,
    required this.fileSystem,
    required this.planReader,
  });
  final SwiftPmFilesystem<T> filesystem;
  final SwiftPmArtifactFileSystem fileSystem;
  final swiftpm_plan_reader.SwiftPmPlanReader planReader;
  List<String> missingSwiftInteropTargets(
    String targetBuildDir, {
    required Set<String> candidates,
  }) {
    final directory = fileSystem.directory(targetBuildDir);
    if (!directory.existsSync()) return const [];
    final reachable = planReader.plannedTargetClosure(
      targetBuildDir,
      swiftpm_plan_reader.pluginsProductName,
    );
    final targets = <String>{};
    final headerPattern = RegExp(r'\bheader\s+"([^"]+-Swift\.h)"');
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is! Directory || !p.basename(entity.path).endsWith('.build')) {
        continue;
      }
      final include = p.join(entity.path, 'include');
      final moduleMap = fileSystem.file(p.join(include, 'module.modulemap'));
      if (!moduleMap.existsSync()) continue;
      for (final match in headerPattern.allMatches(
        moduleMap.readAsStringSync(),
      )) {
        final reference = match.group(1)!;
        final header = p.isAbsolute(reference)
            ? reference
            : p.join(include, reference);
        if (fileSystem.file(header).existsSync()) continue;
        final basename = p.basename(reference);
        final target = basename.substring(
          0,
          basename.length - '-Swift.h'.length,
        );
        if (reachable != null && !reachable.contains(target)) continue;
        if (candidates.contains(target)) {
          targets.add(target);
        }
      }
    }
    final sorted = targets.toList()..sort();
    return sorted;
  }

  Future<void> repairSwiftInteropConsumers({
    required String targetBuildDir,
    required Map<String, Set<String>> consumerProducts,
  }) async {
    final importsByProduct = <String, List<String>>{};
    final importPattern = RegExp(
      r'^\s*@import\s+([A-Za-z_][A-Za-z0-9_]*)\s*;',
      multiLine: true,
    );
    for (final product in {
      for (final products in consumerProducts.values) ...products,
    }) {
      final header = fileSystem.file(
        p.join(targetBuildDir, '$product.build', 'include', '$product-Swift.h'),
      );
      if (!header.existsSync()) continue;
      final imports = {
        for (final match in importPattern.allMatches(header.readAsStringSync()))
          if (match.group(1)! != product) match.group(1)!,
      }.toList()..sort();
      if (imports.isNotEmpty) importsByProduct[product] = imports;
    }

    for (final MapEntry(key: consumer, value: products)
        in consumerProducts.entries) {
      final directory = fileSystem.directory(consumer);
      if (!directory.existsSync()) continue;
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File ||
            !const {'.h', '.m', '.mm'}.contains(p.extension(entity.path))) {
          continue;
        }
        var source = await entity.readAsString();
        final newline = source.contains('\r\n') ? '\r\n' : '\n';
        final original = source;
        for (final product in products) {
          final imports = importsByProduct[product];
          if (imports == null) continue;
          final marker = '@import $product;';
          final markerStart = source.indexOf(marker);
          if (markerStart == -1) continue;
          final missing = [
            for (final imported in imports)
              if (!source.contains('@import $imported;')) '@import $imported;',
          ];
          if (missing.isEmpty) continue;
          var insertAt = markerStart + marker.length;
          if (source.startsWith('\r\n', insertAt)) {
            insertAt += 2;
          } else if (source.startsWith('\n', insertAt) ||
              source.startsWith('\r', insertAt)) {
            insertAt++;
          } else {
            source = source.replaceRange(insertAt, insertAt, newline);
            insertAt += newline.length;
          }
          source = source.replaceRange(
            insertAt,
            insertAt,
            '${missing.join(newline)}$newline',
          );
        }
        if (source != original) {
          await filesystem.writeStable(entity.path, source);
        }
      }
    }
  }
}
