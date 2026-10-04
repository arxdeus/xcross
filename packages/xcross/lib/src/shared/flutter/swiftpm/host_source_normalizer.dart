import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/swift_package_host_patches.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_lexer.dart';

@internal
final class SwiftPmHostSourceNormalizer {
  SwiftPmHostSourceNormalizer({required this.fileSystem});
  final SwiftPmArtifactFileSystem fileSystem;

  /// Rewrites Clang-style `-Wl,<argument>...` manifest tokens into the
  /// equivalent arguments accepted by the Swift compiler driver.
  static String normalizeLinkerFlags(String manifest) =>
      manifest.replaceAllMapped(RegExp(r'"-Wl,([^"\\]+)"'), (match) {
        final arguments = match.group(1)!.split(',');
        if (arguments.any((argument) => argument.isEmpty)) {
          return match.group(0)!;
        }
        return [
          for (final argument in arguments) ...['"-Xlinker"', '"$argument"'],
        ].join(', ');
      });

  String removeMissingResources(String manifest, String packageDir) {
    final targets = SwiftPmManifestLexer.swiftCalls(manifest, '.target');
    final resourcePattern = RegExp(
      r'\.((?:process|copy))\(\s*"([^"]+)"\s*\)\s*,?',
    );
    var result = manifest;
    for (final match
        in resourcePattern.allMatches(manifest).toList().reversed) {
      var root = packageDir;
      for (final target in targets) {
        if (target.start > match.start || target.end < match.end) continue;
        final explicitPath = SwiftPmManifestLexer.namedString(
          target.text,
          'path',
        );
        final name = SwiftPmManifestLexer.namedString(target.text, 'name');
        if (explicitPath != null) {
          root = p.joinAll([packageDir, ...explicitPath.split('/')]);
        } else if (name != null) {
          root = p.join(packageDir, 'Sources', name);
        }
        break;
      }
      final resource = p.joinAll([root, ...match.group(2)!.split('/')]);
      if (fileSystem.typeSync(resource) == FileSystemEntityType.notFound) {
        result = result.replaceRange(match.start, match.end, '');
      }
    }
    return result;
  }

  String normalizeHostManifest(String manifest) {
    var result = SwiftPmHostSourceNormalizer.normalizeLinkerFlags(manifest);
    result = exposeMacOSPackageGraphEntries(result);
    result = result.replaceAllMapped(
      RegExp(r'(path:\s*"FirebaseSessions/Sources",)(\s*)(cSettings:)'),
      (match) => '${match[1]}${match[2]}sources: ["."],${match[2]}${match[3]}',
    );
    result = result.replaceAllMapped(
      RegExp(r'(name:\s*"GoogleDataTransport",)(\s*)(platforms:)'),
      (match) =>
          '${match[1]}${match[2]}defaultLocalization: "en",${match[2]}${match[3]}',
    );
    result = result.replaceAllMapped(
      RegExp(r'"([^"\r\n]+)/"'),
      (match) => '"${match[1]}"',
    );
    // Package manifests cannot import Foundation; stdlib String(cString:)
    // already decodes UTF-8 (getsentry/sentry-cocoa#7797).
    result = result.replaceAllMapped(
      RegExp(r'String\(cString:\s*([^,]+),\s*encoding:\s*\.utf8\)'),
      (match) => 'String(cString: ${match[1]})',
    );
    final sourceProduct = RegExp(
      r'products\.append\(\s*\.library\([\s\S]*?\)\s*\)',
    ).firstMatch(result);
    if (result.contains('EXPERIMENTAL_SPM_BUILDS') &&
        sourceProduct != null &&
        !result.contains('products.removeAll()')) {
      final blockStart = result.lastIndexOf('{', sourceProduct.start);
      if (blockStart >= 0) {
        result = result.replaceRange(
          blockStart + 1,
          blockStart + 1,
          '\n    products.removeAll()\n    targets.removeAll()',
        );
      }
    }
    return result;
  }

  /// Injects `import <fallback>` lines ahead of imports of a package whose
  /// Windows build fell back to source and needs its Swift half imported
  /// alongside its Objective-C compatibility module (see
  /// [synthesizeBinaryFallbackCompatibility]).
  ///
  /// `#Preview` no longer needs handling here: [writePreviewMacroStub]
  /// answers the macro through Swift's own plugin protocol, so preview
  /// declarations compile unmodified instead of being blanked out.
  static String normalizeHostSwiftSource(
    String source, {
    Map<String, List<String>> fallbackSwiftModules = const {},
  }) {
    if (fallbackSwiftModules.isEmpty) return source;

    final importPattern = RegExp(
      r'^([ \t]*(?:(?:@[A-Za-z_][\w.]*(?:\([^\r\n]*\))?[ \t]+)*)'
      r'import[ \t]+)([A-Za-z_][A-Za-z0-9_]*)([ \t]*)(\r?\n|$)',
      multiLine: true,
    );
    final importCode = SwiftPmManifestLexer.swiftCodeMask(source);
    final seen = <String>{};
    for (final match in importPattern.allMatches(source)) {
      final importOffset = match.start + match[1]!.lastIndexOf('import');
      if (importCode[importOffset]) {
        seen.add('${match[1]}${match[2]}');
      }
    }
    return source.replaceAllMapped(importPattern, (match) {
      final importOffset = match.start + match[1]!.lastIndexOf('import');
      if (!importCode[importOffset]) {
        return match[0]!;
      }
      final modules = fallbackSwiftModules[match[2]];
      if (modules == null) return match[0]!;
      final imports = [
        for (final module in modules)
          if (seen.add('${match[1]}$module')) '${match[1]}$module',
      ];
      if (imports.isEmpty) return match[0]!;
      final newline = match[4]!.isEmpty ? '\n' : match[4]!;
      return '${imports.join(newline)}$newline${match[0]}';
    });
  }

  /// Normalizes regular Swift source files below [root] without following
  /// links. Every source is analyzed before any file is changed.
  Future<void> normalizeHostSwiftTree(
    String root, {
    Map<String, List<String>> fallbackSwiftModules = const {},
  }) async {
    if (fileSystem.typeSync(root, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    final files = <File>[];

    Future<void> collect(String directory) async {
      await for (final entity
          in fileSystem.directory(directory).list(followLinks: false)) {
        final type = fileSystem.typeSync(entity.path, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          await collect(entity.path);
        } else if (type == FileSystemEntityType.file &&
            p.extension(entity.path) == '.swift') {
          final name = p.basename(entity.path);
          if (name != 'Package.swift' &&
              !(name.startsWith('Package@') && name.endsWith('.swift'))) {
            files.add(fileSystem.file(entity.path));
          }
        }
      }
    }

    await collect(root);
    final changes = <File, String>{};
    for (final file in files) {
      final original = await file.readAsString();
      final normalized = SwiftPmHostSourceNormalizer.normalizeHostSwiftSource(
        original,
        fallbackSwiftModules: fallbackSwiftModules,
      );
      if (normalized != original) changes[file] = normalized;
    }
    for (final change in changes.entries) {
      await change.key.writeAsString(change.value);
    }
  }
}
