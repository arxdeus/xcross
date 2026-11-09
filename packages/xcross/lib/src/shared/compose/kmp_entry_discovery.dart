import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
import 'package:xcross/src/shared/compose/swift/swift_host_paths.dart';
import 'package:xcross/src/shared/compose/swift/swift_import.dart';
import 'package:xcross/src/shared/compose/swift/swift_import_scanner.dart';
import 'package:xcross/src/shared/errors/errors.dart';

@internal
final class ComposeCandidate {
  const ComposeCandidate(
    this.moduleName,
    this.modulePath,
    this.baseName, {
    this.isStaticFramework = false,
  });
  final String moduleName;
  final String modulePath;
  final String baseName;
  final bool isStaticFramework;
}

@internal
final class ComposeEntryResult {
  const ComposeEntryResult(
    this.kind, {
    this.entryClass,
    this.entrySelector,
    this.swiftAppDir,
    this.swiftSources = const [],
    this.swiftImports = const [],
  });
  final KmpEntryKind kind;
  final String? entryClass;
  final String? entrySelector;
  final String? swiftAppDir;
  final List<String> swiftSources;
  final List<SwiftImport> swiftImports;
}

@internal
final class KmpEntryDiscovery {
  const KmpEntryDiscovery(this.files);
  final HostFileSystemInterface files;
  ComposeCandidate pickBySwiftImport(
    String projectRoot,
    List<ComposeCandidate> candidates,
  ) {
    final iosAppDir = files.directory(p.join(projectRoot, swiftHostDirectory));
    final supported = <ComposeCandidate>{};
    if (iosAppDir.existsSync()) {
      for (final file
          in iosAppDir
              .listSync(recursive: true)
              .whereType<File>()
              .where(
                (f) => isSwiftHostSource(f.path, projectRoot: projectRoot),
              )) {
        final source = file.readAsStringSync();
        // Exact top-level module match: `import SharedUI` must not select a
        // `Shared` candidate, and commented-out imports do not count.
        // Conditional imports still count: the app names the framework even
        // if only some platforms import it.
        final modules = {
          for (final i in scanSwiftImports(source, path: file.path)) i.module,
        };
        supported.addAll(candidates.where((c) => modules.contains(c.baseName)));
      }
    }
    if (supported.length == 1) return supported.single;
    throw XcrossError(
      'Found multiple KMP iOS framework modules: ${candidates.map((c) => c.moduleName).join(', ')}. Add an iosApp Swift import to disambiguate.',
    );
  }

  ComposeEntryResult classifyEntry(
    String modulePath,
    String projectRoot,
    String baseName,
  ) {
    final kotlinEntry = _detectKotlinEntry(modulePath);
    final swiftEntry = _detectSwiftAppEntry(projectRoot, baseName);
    if (swiftEntry != null && kotlinEntry == null) return swiftEntry;
    if (kotlinEntry != null) return kotlinEntry;
    return const ComposeEntryResult(KmpEntryKind.frameworkOnly);
  }

  ComposeEntryResult? _detectKotlinEntry(String modulePath) {
    final iosMain = files.directory(p.join(modulePath, 'src', 'iosMain'));
    if (!iosMain.existsSync()) return null;
    final pattern = RegExp(
      r'fun\s+([A-Z][A-Za-z0-9_]*)\s*\([^)]*\)\s*(?::\s*UIViewController\b|=\s*ComposeUIViewController\b)',
    );
    for (final file
        in iosMain
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.kt'))) {
      final source = file.readAsStringSync();
      if (!source.contains('ComposeUIViewController') &&
          !pattern.hasMatch(source)) {
        continue;
      }
      final basename = p.basenameWithoutExtension(file.path);
      final match = pattern.firstMatch(source);
      return ComposeEntryResult(
        KmpEntryKind.runnableApp,
        entryClass: '${basename}Kt',
        entrySelector: match?.group(1) ?? basename,
      );
    }
    return null;
  }

  ComposeEntryResult? _detectSwiftAppEntry(
    String projectRoot,
    String baseName,
  ) {
    final iosApp = files.directory(p.join(projectRoot, swiftHostDirectory));
    if (!iosApp.existsSync()) return null;
    final allSwift = iosApp
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => isSwiftHostSource(f.path, projectRoot: projectRoot))
        .toList();
    File? mainFile;
    for (final file in allSwift) {
      final source = file.readAsStringSync();
      if (isSwiftAppHost(source)) {
        mainFile = file;
        break;
      }
    }
    if (mainFile == null) return null;
    final appDir = p.dirname(mainFile.path);
    final sources =
        files
            .directory(appDir)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => isSwiftHostSource(f.path, projectRoot: projectRoot))
            .map((f) => f.path)
            .toList()
          ..sort();
    // Whether each imported module exists is decided at build time against
    // the real SDK, so discovery only records them instead of allowlisting.
    final imports = [
      for (final source in sources)
        ...scanSwiftImports(
          files.file(source).readAsStringSync(),
          path: source,
        ),
    ];
    return ComposeEntryResult(
      KmpEntryKind.swiftApp,
      swiftAppDir: appDir,
      swiftSources: sources,
      swiftImports: imports,
    );
  }

  /// `@main` type declaration conforming to `App` (or `SwiftUI.App`), ignoring
  /// comments and string literals. UIKit delegates do not match.
  @visibleForTesting
  static bool isSwiftAppHost(String source) {
    final t = tokenizeSwiftCode(source);
    const decls = {'struct', 'class', 'enum', 'actor'};
    for (var i = 0; i < t.length; i++) {
      if (t[i] != '@' || i + 1 >= t.length || t[i + 1] != 'main') continue;
      var j = i + 2;
      // Skip further attributes and modifiers until the declaration keyword.
      while (j < t.length && !decls.contains(t[j])) {
        if (t[j] == '{' || t[j] == '}' || t[j] == ';') {
          break;
        }
        if (t[j] == '(') {
          var depth = 0;
          for (; j < t.length; j++) {
            if (t[j] == '(') depth++;
            if (t[j] == ')' && --depth == 0) break;
          }
        }
        j++;
      }
      if (j >= t.length || !decls.contains(t[j])) continue;
      j += 2; // keyword and name
      if (j < t.length && t[j] == '<') {
        var depth = 0;
        for (; j < t.length; j++) {
          if (t[j] == '<') depth++;
          if (t[j] == '>' && --depth == 0) break;
        }
        j++;
      }
      if (j >= t.length || t[j] != ':') continue;
      for (j++; j < t.length && t[j] != '{' && t[j] != 'where'; j++) {
        if (t[j] == 'App' || t[j] == 'SwiftUI.App') return true;
      }
    }
    return false;
  }
}

/// Splits Swift [source] into identifier (dotted) and single-char punctuation
/// tokens, dropping comments (nested) and string literals.
@internal
List<String> tokenizeSwiftCode(String source) {
  final out = <String>[];
  final n = source.length;
  var i = 0;
  bool isId(int c) =>
      c == 0x5f ||
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5a) ||
      (c >= 0x61 && c <= 0x7a) ||
      c > 0x7f;
  while (i < n) {
    final c = source[i];
    if (c == '/' && i + 1 < n && source[i + 1] == '/') {
      while (i < n && source[i] != '\n') {
        i++;
      }
    } else if (c == '/' && i + 1 < n && source[i + 1] == '*') {
      var depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (source.startsWith('/*', i)) {
          depth++;
          i += 2;
        } else if (source.startsWith('*/', i)) {
          depth--;
          i += 2;
        } else {
          i++;
        }
      }
    } else if (c == '"' || c == '#') {
      var hashes = 0;
      var k = i;
      while (k < n && source[k] == '#') {
        hashes++;
        k++;
      }
      if (hashes > 0 && k < n && source[k] == '/') {
        // Extended regex literal `#/.../#`, skipped like the import scanner
        // does so both agree on what is code.
        final closer = '/${'#' * hashes}';
        final end = source.indexOf(closer, k + 1);
        i = end < 0 ? n : end + closer.length;
        continue;
      }
      if (k >= n || source[k] != '"') {
        i = k;
        continue;
      }
      final multi = source.startsWith('"""', k);
      final quote = multi ? '"""' : '"';
      final close = quote + '#' * hashes;
      i = k + quote.length;
      while (i < n && !source.startsWith(close, i)) {
        if (source[i] == r'\' && hashes == 0) i++;
        if (!multi && i < n && source[i] == '\n') break;
        i++;
      }
      i += close.length;
    } else if (isId(c.codeUnitAt(0))) {
      final start = i;
      while (i < n &&
          (isId(source.codeUnitAt(i)) ||
              (source[i] == '.' &&
                  i + 1 < n &&
                  isId(source.codeUnitAt(i + 1))))) {
        i++;
      }
      out.add(source.substring(start, i));
    } else {
      if (c.trim().isNotEmpty) out.add(c);
      i++;
    }
  }
  return out;
}
