import 'dart:async';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/clang_modules.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_lexer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/module_files.dart';

@internal
const String flutterFrameworkPackageName = 'FlutterFramework';
@internal
const String pluginsProductName = 'FlutterPluginsGenerated';

@internal
final class SwiftPmSourceFallback<T extends PlatformHostInterface> {
  SwiftPmSourceFallback({required this.filesystem, required this.moduleFiles});
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

  String aliasBinaryFallbackProducts(
    String manifest, {
    required Set<String> consumedProducts,
  }) {
    var result = manifest;
    for (final product in consumedProducts.toList()..sort()) {
      final source = fallbackSource(result, product);
      if (source == null ||
          source.sourceProduct.name == product ||
          source.fallbackProducts.any((entry) => entry.name == product)) {
        continue;
      }
      final targets = source.sourceProduct.targets
          .map((name) => '"$name"')
          .join(', ');
      result = result.replaceRange(
        source.fallback.close,
        source.fallback.close,
        '    products.append(.library(name: "$product", targets: [$targets]))\n',
      );
    }
    return result;
  }

  SwiftPmFallbackSource? fallbackSource(String manifest, String product) {
    final fallback = SwiftPmManifestLexer.fallbackBlock(manifest);
    if (fallback == null) return null;
    final isClangIdentifier = RegExp(
      r'^[A-Za-z_][A-Za-z0-9_]*$',
    ).hasMatch(product);
    if (!isClangIdentifier) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM Clang module "$product": the binary '
        'product name is not a Clang module identifier.',
      );
    }

    final normalManifest = manifest.substring(0, fallback.open);
    if (!_isBinaryBackedProduct(normalManifest, product)) return null;

    final blockText = manifest.substring(fallback.open + 1, fallback.close);
    final synthetic = '_xcross_$product';
    final fallbackProducts = _fallbackProducts(blockText);
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
    return (
      fallback: fallback,
      blockText: blockText,
      fallbackProducts: fallbackProducts,
      sourceProduct: sourceProduct,
    );
  }

  static bool _isBinaryBackedProduct(String normalManifest, String product) {
    final binaryTargets = {
      for (final call in SwiftPmManifestLexer.swiftCalls(
        normalManifest,
        '.binaryTarget',
      ))
        if (SwiftPmManifestLexer.namedString(call.text, 'name')
            case final String name)
          name,
    };
    return SwiftPmManifestLexer.swiftCalls(normalManifest, '.library').any(
      (call) =>
          SwiftPmManifestLexer.namedString(call.text, 'name') == product &&
          SwiftPmManifestLexer.namedStringList(
            call.text,
            'targets',
          ).any(binaryTargets.contains),
    );
  }

  static List<SwiftPmFallbackProduct> _fallbackProducts(String blockText) {
    final productCalls = SwiftPmManifestLexer.swiftCalls(blockText, '.library');
    return [
      for (final call in productCalls)
        (
          call: call,
          name: SwiftPmManifestLexer.namedString(call.text, 'name'),
          targets: SwiftPmManifestLexer.namedStringList(call.text, 'targets'),
        ),
    ].where((entry) => entry.name != null && entry.targets.isNotEmpty).toList();
  }

  Future<String> synthesizeBinaryFallbackProduct(
    String manifest, {
    required String packageDir,
    required String product,
    Map<String, List<String>>? fallbackSwiftModules,
  }) async {
    final source = fallbackSource(manifest, product);
    if (source == null) return manifest;
    final (:fallback, :blockText, :fallbackProducts, :sourceProduct) = source;
    final synthetic = '_xcross_$product';

    final targets = _fallbackTargets(blockText);
    final closure = _targetClosure(
      targets,
      roots: sourceProduct.targets,
      synthetic: synthetic,
      product: product,
    );
    final headerTargets = _headerTargets(
      targets,
      closure: closure,
      packageDir: packageDir,
      product: product,
    );
    if (headerTargets == null) return manifest;

    final canonical = _canonicalModuleMap(packageDir, product);
    final canonicalBlock = SwiftPmClangModules.moduleBlock(
      canonical.text,
      product,
    )!;
    final publicModule = _publicHeaderModule(
      canonical.text,
      canonicalBlock,
      headerTargets: headerTargets,
      packageDir: packageDir,
      product: product,
    );

    final swiftModules = _swiftModules(
      targets,
      closure: closure,
      packageDir: packageDir,
    );
    if (fallbackSwiftModules != null) {
      fallbackSwiftModules[product] = swiftModules;
    }

    final compatibilityDir = p.join(packageDir, '.xcross', synthetic);
    final includeDir = p.join(compatibilityDir, 'include');
    final moduleMap = _compatibilityModuleMap(
      canonical.text,
      canonicalBlock,
      packageDir: packageDir,
      product: product,
    );

    await filesystem.artifactFileSystem
        .directory(includeDir)
        .create(recursive: true);
    final shim = _compatibilityShim(publicModule, swiftModules);
    await filesystem.writeStable(p.join(includeDir, '$product.h'), shim);
    await filesystem.writeStable(
      p.join(includeDir, 'module.modulemap'),
      moduleMap,
    );
    await filesystem.writeStable(
      p.join(compatibilityDir, '$synthetic.m'),
      '#import "$product.h"\n',
    );

    final rewrittenBlock = _rewriteFallbackBlock(
      blockText,
      fallbackProducts: fallbackProducts,
      sourceProduct: sourceProduct,
      targets: targets,
      closure: closure,
      product: product,
      synthetic: synthetic,
    );
    return manifest.replaceRange(
      fallback.open + 1,
      fallback.close,
      rewrittenBlock,
    );
  }

  static Map<String, _FallbackTarget> _fallbackTargets(String blockText) {
    final targetCalls = SwiftPmManifestLexer.swiftCalls(blockText, '.target');
    final targets = <String, _FallbackTarget>{};
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
        headers: SwiftPmManifestLexer.namedString(
          call.text,
          'publicHeadersPath',
        ),
        sources: SwiftPmManifestLexer.namedStringList(call.text, 'sources'),
        excludes: SwiftPmManifestLexer.namedStringList(call.text, 'exclude'),
      );
    }
    return targets;
  }

  static List<String> _targetClosure(
    Map<String, _FallbackTarget> targets, {
    required List<String> roots,
    required String synthetic,
    required String product,
  }) {
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

    for (final target in roots) {
      visit(target);
    }
    if (closure.isEmpty) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM module "$product": its fallback target '
        'closure is empty.',
      );
    }
    return closure;
  }

  List<({String name, String root, List<String> modules})>? _headerTargets(
    Map<String, _FallbackTarget> targets, {
    required List<String> closure,
    required String packageDir,
    required String product,
  }) {
    final headerTargets =
        <({String name, String root, List<String> modules})>[];
    for (final name in closure) {
      final target = targets[name]!;
      if (target.headers == null) continue;
      final root = p.normalize(p.join(packageDir, target.path, target.headers));
      final moduleMap = filesystem.artifactFileSystem.file(
        p.join(root, 'module.modulemap'),
      );
      final modules = moduleMap.existsSync()
          ? SwiftPmClangModules.topLevelModuleNames(
              moduleMap.readAsStringSync(),
            )
          : [name];
      if (modules.contains(product)) return null;
      if (modules.isNotEmpty) {
        headerTargets.add((name: name, root: root, modules: modules));
      }
    }
    return headerTargets;
  }

  ({File file, String text}) _canonicalModuleMap(
    String packageDir,
    String product,
  ) {
    final canonicalMaps = <({File file, String text})>[];
    final entities = filesystem.artifactFileSystem
        .directory(packageDir)
        .listSync(recursive: true, followLinks: false);
    for (final entity in entities) {
      if (entity is! File || !_isModuleMapEvidence(packageDir, entity)) {
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
    return canonicalMaps.single;
  }

  bool _isModuleMapEvidence(String packageDir, File file) {
    final ignored = SwiftPmModuleFiles.ignoredPackageEvidencePath(
      packageDir,
      filesystem.artifactFileSystem.processPath(file.path),
    );
    if (ignored) return false;
    final basename = p.basename(file.path);
    return basename == 'module.modulemap' || basename.endsWith('.modulemap');
  }

  String _publicHeaderModule(
    String canonicalText,
    ({int start, int open, int close}) canonicalBlock, {
    required List<({String name, String root, List<String> modules})>
    headerTargets,
    required String packageDir,
    required String product,
  }) {
    final publicHeaders = [
      for (final header in SwiftPmClangModules.directModuleHeaders(
        canonicalText,
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
    final isUnambiguous =
        publicModules.length == 1 && publicModules.single.modules.length == 1;
    if (!isUnambiguous) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM module "$product": the fallback public '
        'header module is ambiguous.',
      );
    }
    return publicModules.single.modules.single;
  }

  List<String> _swiftModules(
    Map<String, _FallbackTarget> targets, {
    required List<String> closure,
    required String packageDir,
  }) {
    final swiftModules = <String>[];
    for (final name in closure) {
      final target = targets[name]!;
      final rootPath = p.join(packageDir, target.path);
      final rootExists = filesystem.artifactFileSystem
          .directory(rootPath)
          .existsSync();
      if (!rootExists) continue;
      final sourceRoots = target.sources.isEmpty
          ? [rootPath]
          : [for (final source in target.sources) p.join(rootPath, source)];
      final hasSwift = sourceRoots.any(
        (sourceRoot) => _hasSwiftSource(sourceRoot, rootPath, target.excludes),
      );
      if (hasSwift) swiftModules.add(name);
    }
    return swiftModules;
  }

  bool _hasSwiftSource(
    String sourceRoot,
    String rootPath,
    List<String> excludes,
  ) {
    final directory = filesystem.artifactFileSystem.directory(sourceRoot);
    if (directory.existsSync()) {
      final entities = directory.listSync(recursive: true, followLinks: false);
      return entities.any((entity) {
        if (entity is! File || !entity.path.endsWith('.swift')) {
          return false;
        }
        final relative = p.relative(
          filesystem.artifactFileSystem.processPath(entity.path),
          from: rootPath,
        );
        return !excludes.any(
          (excluded) =>
              p.equals(relative, excluded) || p.isWithin(excluded, relative),
        );
      });
    }
    return sourceRoot.endsWith('.swift') &&
        filesystem.artifactFileSystem.file(sourceRoot).existsSync();
  }

  String _compatibilityModuleMap(
    String canonicalText,
    ({int start, int open, int close}) canonicalBlock, {
    required String packageDir,
    required String product,
  }) {
    final nested = [
      for (final module in SwiftPmClangModules.directNestedModules(
        canonicalText,
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
    return moduleMap.toString();
  }

  static String _compatibilityShim(
    String publicModule,
    List<String> swiftModules,
  ) {
    final shim = StringBuffer()..writeln('@import $publicModule;');
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
    return shim.toString();
  }

  static String _rewriteFallbackBlock(
    String blockText, {
    required List<SwiftPmFallbackProduct> fallbackProducts,
    required SwiftPmFallbackProduct sourceProduct,
    required Map<String, _FallbackTarget> targets,
    required List<String> closure,
    required String product,
    required String synthetic,
  }) {
    final syntheticCount = fallbackProducts
        .singleWhere((entry) => entry.call.start == sourceProduct.call.start)
        .targets
        .where((name) => name == synthetic)
        .length;
    var rewrittenBlock = blockText;
    final needsSyntheticTarget =
        sourceProduct.name == product && syntheticCount != 1;
    if (needsSyntheticTarget) {
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
    final needsProductAlias =
        sourceProduct.name != product &&
        !fallbackProducts.any((entry) => entry.name == product);
    if (needsProductAlias) {
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
    return '${rewrittenBlock.trimRight()}\n$additions';
  }
}

@internal
typedef SwiftPmManifestCall = ({int start, int end, String text});

@internal
typedef SwiftPmFallbackProduct = ({
  SwiftPmManifestCall call,
  String? name,
  List<String> targets,
});

@internal
typedef SwiftPmFallbackSource = ({
  ({int open, int close}) fallback,
  String blockText,
  List<SwiftPmFallbackProduct> fallbackProducts,
  SwiftPmFallbackProduct sourceProduct,
});

typedef _FallbackTarget = ({
  String call,
  List<String> dependencies,
  String path,
  String? headers,
  List<String> sources,
  List<String> excludes,
});
