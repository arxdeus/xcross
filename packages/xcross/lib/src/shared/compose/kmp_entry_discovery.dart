import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
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
    this.swiftImports = const {},
  });
  final KmpEntryKind kind;
  final String? entryClass;
  final String? entrySelector;
  final String? swiftAppDir;
  final List<String> swiftSources;
  final Set<String> swiftImports;
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
        supported.addAll(
          candidates.where((c) => source.contains('import ${c.baseName}')),
        );
      }
    }
    if (supported.length == 1) return supported.single;
    throw XcrossError(
      'Found multiple KMP iOS framework modules: ${candidates.map((c) => c.moduleName).join(', ')}. Add an iosApp Swift import to disambiguate.',
    );
  }

  static const _allowedSwiftImports = {
    'SwiftUI',
    'UIKit',
    'Foundation',
    'Combine',
    'SwiftData',
    'CoreGraphics',
    'CoreFoundation',
    'Observation',
    'os',
    'Dispatch',
  };

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
      if (source.contains('@main') && RegExp(r':\s*App\b').hasMatch(source)) {
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
    final imports = <String>{};
    final importRe = RegExp(r'^import\s+(\w+)', multiLine: true);
    for (final source in sources) {
      for (final match in importRe.allMatches(
        files.file(source).readAsStringSync(),
      )) {
        imports.add(match.group(1)!);
      }
    }
    final allowed = {..._allowedSwiftImports, baseName};
    if (imports.any((import) => !allowed.contains(import))) return null;
    return ComposeEntryResult(
      KmpEntryKind.swiftApp,
      swiftAppDir: appDir,
      swiftSources: sources,
      swiftImports: imports,
    );
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
