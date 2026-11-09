import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
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
    final iosAppDir = files.directory(p.join(projectRoot, 'iosApp'));
    final supported = <ComposeCandidate>{};
    if (iosAppDir.existsSync()) {
      for (final file
          in iosAppDir
              .listSync(recursive: true)
              .whereType<File>()
              .where(
                (f) => f.path.endsWith('.swift') && !_excludeSwiftPath(f.path),
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
    final iosApp = files.directory(p.join(projectRoot, 'iosApp'));
    if (!iosApp.existsSync()) return null;
    final allSwift = iosApp
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.swift') && !_excludeSwiftPath(f.path))
        .toList();
    File? mainFile;
    for (final file in allSwift) {
      final source = file.readAsStringSync();
      if (_isSwiftAppHost(source)) {
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
            .where(
              (f) => f.path.endsWith('.swift') && !_excludeSwiftPath(f.path),
            )
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

  /// `@main` (same or previous line) on a type conforming to `App`, ignoring
  /// matches inside comments.
  static bool _isSwiftAppHost(String source) {
    final code = source
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
        .replaceAll(RegExp(r'//[^\n]*'), '');
    return RegExp(
      r'@main\b[^{;]*?\b(?:struct|class|final\s+class)\s+\w+\s*:[^{]*\bApp\b',
    ).hasMatch(code);
  }

  bool _excludeSwiftPath(String path) => path
      .split(p.separator)
      .any(
        (segment) =>
            segment == 'Preview Content' ||
            segment.endsWith('Tests') ||
            segment.endsWith('UITests'),
      );
}
