import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/clang_modules.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_lexer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/module_files.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmSourceFallback<T extends PlatformHostInterface> {
  SwiftPmSourceFallback({required this.filesystem,required this.moduleFiles});
  final SwiftPmFilesystem<T> filesystem;
final SwiftPmModuleFiles moduleFiles;


  /// Adds a dependency-scoped Clang module when a source fallback preserves
  /// its implementation modules but no longer emits a consumed binary module.
  Future<String> synthesizeBinaryFallbackCompatibility(
    String manifest, {
    required String packageDir,
    required Set<String> consumedProducts,
    Map<String, List<String>>? fallbackSwiftModules,
  }) async {
    var result = manifest;
    for (final product in consumedProducts) {
      result = await synthesizeBinaryFallbackProduct(
        result,
        packageDir: packageDir,
        product: product,
        fallbackSwiftModules: fallbackSwiftModules,
      );
    }
    return result;
  }

  Future<String> synthesizeBinaryFallbackProduct(
    String manifest, {
    required String packageDir,
    required String product,
    Map<String, List<String>>? fallbackSwiftModules,
  }) async {
    final fallback = SwiftPmManifestLexer.fallbackBlock(manifest);
    if (fallback == null) return manifest;
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(product)) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM Clang module "$product": the binary '
        'product name is not a Clang module identifier.',
      );
    }

    final normalManifest = manifest.substring(0, fallback.open);
    final binaryTargets = {
      for (final call in SwiftPmManifestLexer.swiftCalls(
        normalManifest,
        '.binaryTarget',
      ))
        if (SwiftPmManifestLexer.namedString(call.text, 'name')
            case final String name)
          name,
    };
    final binaryBacked = SwiftPmManifestLexer.swiftCalls(normalManifest, '.library')
        .any(
          (call) =>
              SwiftPmManifestLexer.namedString(call.text, 'name') == product &&
              SwiftPmManifestLexer.namedStringList(
                call.text,
                'targets',
              ).any(binaryTargets.contains),
        );
    if (!binaryBacked) return manifest;

    final blockText = manifest.substring(fallback.open + 1, fallback.close);
    final synthetic = '_xcross_$product';
    final productCalls = SwiftPmManifestLexer.swiftCalls(blockText, '.library');
    final fallbackProducts = [
      for (final call in productCalls)
        (
          call: call,
          name: SwiftPmManifestLexer.namedString(call.text, 'name'),
          targets: SwiftPmManifestLexer.namedStringList(call.text, 'targets'),
        ),
    ].where((entry) => entry.name != null && entry.targets.isNotEmpty).toList();
    final sourceProducts = [
      for (final entry in fallbackProducts)
        (
          call: entry.call,
          name: entry.name,
          targets: entry.targets.where((name) => name != synthetic).toList(),
        ),
    ].where((entry) => entry.targets.isNotEmpty).toList();
    final matchingProducts = sourceProducts
        .where((entry) => entry.name == product)
        .toList();
    final sourceProduct = matchingProducts.length == 1
        ? matchingProducts.single
        : sourceProducts.length == 1
        ? sourceProducts.single
        : null;
    if (sourceProduct == null) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM module "$product": the fallback product '
        'is ambiguous (${sourceProducts.map((entry) => entry.name).join(', ')}).',
      );
    }

    final targetCalls = SwiftPmManifestLexer.swiftCalls(blockText, '.target');
    final targets =
        <
          String,
          ({
            String call,
            List<String> dependencies,
            String path,
            String? headers,
            List<String> sources,
            List<String> excludes,
          })
        >{};
    for (final call in targetCalls) {
      final name = SwiftPmManifestLexer.namedString(call.text, 'name');
      if (name == null) continue;
      targets[name] = (
        call: call.text,
        dependencies: SwiftPmManifestLexer.namedStringList(
          call.text,
          'dependencies',
        ),
        path:
            SwiftPmManifestLexer.namedString(call.text, 'path') ??
            p.join('Sources', name),
        headers: SwiftPmManifestLexer.namedString(call.text, 'publicHeadersPath'),
        sources: SwiftPmManifestLexer.namedStringList(call.text, 'sources'),
        excludes: SwiftPmManifestLexer.namedStringList(call.text, 'exclude'),
      );
    }

    final closure = <String>[];
    final visiting = <String>{};
    void visit(String name) {
      if (name == synthetic ||
          !targets.containsKey(name) ||
          !visiting.add(name)) {
        return;
      }
      closure.add(name);
      for (final dependency in targets[name]!.dependencies) {
        visit(dependency);
      }
    }

    for (final target in sourceProduct.targets) {
      visit(target);
    }
    if (closure.isEmpty) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM module "$product": its fallback target '
        'closure is empty.',
      );
    }

    final headerTargets =
        <({String name, String root, List<String> modules})>[];
    for (final name in closure) {
      final target = targets[name]!;
      if (target.headers == null) continue;
      final root = p.normalize(p.join(packageDir, target.path, target.headers));
      final moduleMap = File(p.join(root, 'module.modulemap'));
      final modules = moduleMap.existsSync()
          ? SwiftPmClangModules.topLevelModuleNames(moduleMap.readAsStringSync())
          : [name];
      if (modules.contains(product)) return manifest;
      if (modules.isNotEmpty) {
        headerTargets.add((name: name, root: root, modules: modules));
      }
    }

    final canonicalMaps = <({File file, String text})>[];
    for (final entity in Directory(
      packageDir,
    ).listSync(recursive: true, followLinks: false)) {
      if (entity is! File ||
          SwiftPmModuleFiles.ignoredPackageEvidencePath(packageDir, entity.path) ||
          !(p.basename(entity.path) == 'module.modulemap' ||
              p.basename(entity.path).endsWith('.modulemap'))) {
        continue;
      }
      final text = entity.readAsStringSync();
      if (SwiftPmClangModules.moduleBlock(text, product) != null) {
        canonicalMaps.add((file: entity, text: text));
      }
    }
    if (canonicalMaps.length != 1) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM module "$product": expected one canonical '
        'module map, found ${canonicalMaps.length}.',
      );
    }
    final canonical = canonicalMaps.single;
    final canonicalBlock = SwiftPmClangModules.moduleBlock(
      canonical.text,
      product,
    )!;
    final publicHeaders = [
      for (final header in SwiftPmClangModules.directModuleHeaders(
        canonical.text,
        canonicalBlock,
      ))
        moduleFiles.resolveModuleReference(
          packageDir,
          header.path,
          directory: header.directory,
        ),
    ];
    final publicModules = headerTargets.where((target) {
      return publicHeaders.every(
        (header) =>
            p.equals(header, target.root) || p.isWithin(target.root, header),
      );
    }).toList();
    if (publicModules.length != 1 || publicModules.single.modules.length != 1) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM module "$product": the fallback public '
        'header module is ambiguous.',
      );
    }

    final swiftModules = <String>[];
    for (final name in closure) {
      final target = targets[name]!;
      final root = Directory(p.join(packageDir, target.path));
      if (!root.existsSync()) continue;
      final sourceRoots = target.sources.isEmpty
          ? [root.path]
          : [for (final source in target.sources) p.join(root.path, source)];
      final hasSwift = sourceRoots.any((sourceRoot) {
        final directory = Directory(sourceRoot);
        if (directory.existsSync()) {
          return directory.listSync(recursive: true, followLinks: false).any((
            entity,
          ) {
            if (entity is! File || !entity.path.endsWith('.swift')) {
              return false;
            }
            final relative = p.relative(entity.path, from: root.path);
            return !target.excludes.any(
              (excluded) =>
                  p.equals(relative, excluded) ||
                  p.isWithin(excluded, relative),
            );
          });
        }
        return File(sourceRoot).path.endsWith('.swift') &&
            File(sourceRoot).existsSync();
      });
      if (hasSwift) swiftModules.add(name);
    }
    if (fallbackSwiftModules != null) {
      fallbackSwiftModules[product] = swiftModules;
    }

    final compatibilityDir = p.join(packageDir, '.xcross', synthetic);
    final includeDir = p.join(compatibilityDir, 'include');
    final nested = [
      for (final module in SwiftPmClangModules.directNestedModules(
        canonical.text,
        canonicalBlock,
      ))
        moduleFiles.absoluteNestedModuleHeaders(packageDir, module),
    ];
    final nestedNames = [
      for (final module in nested)
        ...SwiftPmClangModules.topLevelModuleNames(module),
    ];
    final indentedNested = nested
        .map(
          (module) => module
              .replaceFirst(RegExp(r'\{'), '{\n  header "$product.h"')
              .split('\n')
              .map((line) => '  $line')
              .join('\n'),
        )
        .join('\n');
    final moduleMap = StringBuffer()
      ..writeln('module $product {')
      ..writeln('  header "$product.h"')
      ..writeln('  export *');
    for (final name in nestedNames) {
      moduleMap.writeln('  export $name');
    }
    if (indentedNested.isNotEmpty) moduleMap.writeln(indentedNested);
    moduleMap.writeln('}');

    await Directory(includeDir).create(recursive: true);
    final shim = StringBuffer()
      ..writeln('@import ${publicModules.single.modules.single};');
    // The fallback's Swift half completes the Objective-C surface: the
    // headers refer to types the Swift target declares, so a consumer that
    // sees the headers alone imports those declarations as incomplete and
    // loses every member mentioning them. Swift emits an Objective-C
    // interop header for such a target, and SwiftPM puts it on the include
    // path of the targets that depend on it. Prefer that header, because a
    // bare `@import` of a Swift module only resolves once that module is
    // built, which is not the case while Swift builds this very module.
    for (final module in swiftModules) {
      shim
        ..writeln('#if __has_include("$module-Swift.h")')
        ..writeln('#import "$module-Swift.h"')
        ..writeln('#elif !defined(__swift__)')
        ..writeln('@import $module;')
        ..writeln('#endif');
    }
    await filesystem.writeStable(
      p.join(includeDir, '$product.h'),
      shim.toString(),
    );
    await filesystem.writeStable(
      p.join(includeDir, 'module.modulemap'),
      moduleMap.toString(),
    );
    await filesystem.writeStable(
      p.join(compatibilityDir, '$synthetic.m'),
      '#import "$product.h"\n',
    );

    final syntheticCount = fallbackProducts
        .singleWhere((entry) => entry.call.start == sourceProduct.call.start)
        .targets
        .where((name) => name == synthetic)
        .length;
    var rewrittenBlock = blockText;
    if (sourceProduct.name == product && syntheticCount != 1) {
      final targetsPattern = RegExp(r'targets\s*:\s*\[([^\]]*)\]');
      final normalizedTargets = [
        ...sourceProduct.targets,
        synthetic,
      ].map((name) => '"$name"').join(', ');
      final updatedProduct = sourceProduct.call.text.replaceFirst(
        targetsPattern,
        'targets: [$normalizedTargets]',
      );
      rewrittenBlock = rewrittenBlock.replaceRange(
        sourceProduct.call.start,
        sourceProduct.call.end,
        updatedProduct,
      );
    }
    final dependencyList = closure.map((name) => '"$name"').join(', ');
    final additions = StringBuffer();
    if (sourceProduct.name != product &&
        !fallbackProducts.any((entry) => entry.name == product)) {
      additions.writeln(
        '    products.append(.library(name: "$product", '
        'targets: ["$synthetic"]))',
      );
    }
    if (!targets.containsKey(synthetic)) {
      additions.writeln(
        '    targets.append(.target(name: "$synthetic", '
        'dependencies: [$dependencyList], path: ".xcross/$synthetic", '
        'publicHeadersPath: "include"))',
      );
    }
    rewrittenBlock = '${rewrittenBlock.trimRight()}\n$additions';
    return manifest.replaceRange(
      fallback.open + 1,
      fallback.close,
      rewrittenBlock,
    );
  }
}
