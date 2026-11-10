import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
import 'package:xcross/src/shared/compose/swift/swift_host_paths.dart';
import 'package:xcross/src/shared/compose/swift/swift_import.dart';
import 'package:xcross/src/shared/compose/swift/swift_import_scanner.dart';
import 'package:xcross/src/shared/compose/swift/swift_lexer.dart';
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

/// Swift [source] as the word list [KmpEntryDiscovery.isSwiftAppHost]
/// matches on: adjacent dotted names joined (`SwiftUI.App`), directives as
/// their word, other code as single characters, literals dropped. A thin view
/// over [lexSwift], so what counts as code is decided in exactly one place.
@internal
List<String> tokenizeSwiftCode(String source) {
  final out = <String>[];
  // Source offset where the last emitted word ends, or -1 when the last
  // emitted entry is not a word that a following `.name` may extend.
  var wordEnd = -1;
  SwiftToken? dot;
  for (final tok in lexSwift(source)) {
    final word = switch (tok.kind) {
      SwiftTokenKind.identifier || SwiftTokenKind.number => !tok.backticked,
      SwiftTokenKind.directive => tok.text.isNotEmpty,
      _ => false,
    };
    if (word) {
      if (dot != null && dot.start == wordEnd && dot.end == tok.start) {
        out[out.length - 1] += '.${tok.text}';
      } else {
        out.add(tok.text);
      }
      wordEnd = tok.end;
      dot = null;
      continue;
    }
    if (tok.isPunct('.') && dot == null && tok.start == wordEnd) {
      // Held back: it joins the next word or is emitted on its own.
      dot = tok;
      continue;
    }
    if (dot != null) out.add('.');
    dot = null;
    wordEnd = -1;
    if (tok.backticked) {
      // `` `x` `` reads as the backticks around the bare word, as before.
      out
        ..add('`')
        ..addAll(_words(tok.text))
        ..add('`');
    } else if (tok.kind == SwiftTokenKind.punctuation &&
        tok.text.trim().isNotEmpty) {
      out.add(tok.text);
    }
  }
  if (dot != null) out.add('.');
  return out;
}

/// The words and symbols inside a backticked identifier.
List<String> _words(String text) => [
  for (final m in RegExp(r'[0-9A-Za-z_\u0080-\uffff]+|\S').allMatches(text))
    m[0]!,
];
