import 'dart:io';
import 'package:path/path.dart' as p;

import 'package:xcross/src/util/errors.dart';

/// Entry-kind classification for the iOS framework module.
///
/// Phase-1 precedence (stable):
///   runnableApp — Kotlin ComposeUIViewController/UIViewController entry detected
///                 in iosMain; xcross uses the proven ObjC runner path.
///   swiftApp    — SwiftUI `@main : App` host found in iosApp AND no Kotlin UI
///                 entry; xcross compiles the real iosApp sources with swiftc.
///   frameworkOnly — neither of the above; xcross builds only the framework.
///
/// Phase 2 (TODO, not yet): swiftApp will win over runnableApp when both are
/// present, enabling pure SwiftUI apps that embed a Compose UIViewController.
enum KmpEntryKind { runnableApp, swiftApp, frameworkOnly }

/// The resolved iOS-framework module for a KMP project.
class KmpFrameworkModule {
  const KmpFrameworkModule({
    required this.modulePath,
    required this.moduleName,
    required this.baseName,
    required this.entryKind,
    this.entryClass,
    this.entrySelector,
    this.swiftAppDir,
    this.swiftSources,
    this.swiftImports,
  });

  /// Absolute path to the module directory.
  final String modulePath;

  /// Gradle module ID, colon-separated for nested modules.
  /// e.g. `shared`, `sharedLogic`, or `a:b` for `include(":a:b")`.
  /// Use [moduleLeaf] for the leaf segment (init-scripts, klib dir names).
  final String moduleName;

  /// Framework baseName declared in build.gradle.kts, e.g. `Shared`.
  final String baseName;

  final KmpEntryKind entryKind;

  /// For [KmpEntryKind.runnableApp]: the generated Kotlin companion class,
  /// e.g. `MainViewControllerKt`.
  final String? entryClass;

  /// For [KmpEntryKind.runnableApp]: the verbatim Kotlin function name used as
  /// the ObjC selector, e.g. `MainViewController` (NOT lowercased — konanc
  /// exports the selector with the exact capitalisation of the Kotlin `fun`).
  final String? entrySelector;

  /// For [KmpEntryKind.swiftApp]: absolute path to the iosApp target source
  /// directory — the directory that contains the `@main` entry file,
  /// e.g. `<root>/iosApp/iosApp`.
  final String? swiftAppDir;

  /// For [KmpEntryKind.swiftApp]: all `.swift` source files to compile.
  ///
  /// Collected from [swiftAppDir] (recursively), excluding:
  ///   - any path segment named `Preview Content`
  ///   - any path segment ending in `Tests` or `UITests`
  ///
  /// `*_Previews`/`PreviewProvider` STRUCT files (not dirs) are intentionally
  /// KEPT — they compile fine on Linux with swiftc.
  final List<String>? swiftSources;

  /// For [KmpEntryKind.swiftApp]: the set of top-level `import X` module
  /// names found across [swiftSources].
  final Set<String>? swiftImports;

  /// Leaf segment of [moduleName]: the last colon-separated component.
  ///
  /// For flat modules (`shared`) this equals [moduleName].
  /// For nested modules (`a:b`) this is `b`.
  /// Used for Gradle init-script `name` guards and klib directory names.
  String get moduleLeaf => moduleName.split(':').last;

  @override
  String toString() =>
      'KmpFrameworkModule(module=$moduleName, leaf=$moduleLeaf, '
      'baseName=$baseName, entryKind=$entryKind, '
      'entryClass=$entryClass, entrySelector=$entrySelector, '
      'swiftAppDir=$swiftAppDir, '
      'swiftSources=${swiftSources?.length} files, '
      'swiftImports=$swiftImports)';
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Detect the iOS-framework module for a KMP project rooted at [projectRoot].
///
/// Throws [XcrossError] with an actionable message when detection fails.
KmpFrameworkModule detectKmpFramework(String projectRoot) {
  final root = Directory(projectRoot);
  if (!root.existsSync()) {
    throw XcrossError(
      'KMP project root not found: $projectRoot',
    );
  }

  // ── 1. Parse settings.gradle.kts (or .gradle) for included modules ────────
  final settingsFile = _findFile(root.path, [
    'settings.gradle.kts',
    'settings.gradle',
  ]);
  if (settingsFile == null) {
    throw XcrossError(
      'No settings.gradle.kts found in $projectRoot. '
      'Is this a Gradle KMP project?',
    );
  }

  final modules =
      _parseIncludedModules(settingsFile.readAsStringSync(), root.path);
  if (modules.isEmpty) {
    throw XcrossError(
      'No included modules found in ${settingsFile.path}.',
    );
  }

  // ── 2. Find modules with iosArm64 + binaries.framework ───────────────────
  final candidates = <_Candidate>[];
  for (final spec in modules) {
    final buildFile = _findFile(spec.diskPath, [
      'build.gradle.kts',
      'build.gradle',
    ]);
    if (buildFile == null) continue;

    final content = buildFile.readAsStringSync();
    if (!_hasIosArm64(content)) continue;
    if (!_hasFrameworkBlock(content)) continue;

    final baseName = _extractBaseName(content) ?? _capitalize(spec.leaf);
    candidates.add(_Candidate(spec.gradleId, spec.diskPath, baseName));
  }

  if (candidates.isEmpty) {
    throw XcrossError(
      'No KMP module with iosArm64() + binaries.framework found in '
      '$projectRoot. Check your build.gradle.kts files.',
    );
  }

  // ── 3. Disambiguate via iosApp/**/*.swift imports ─────────────────────────
  final chosen = candidates.length == 1
      ? candidates.first
      : _pickBySwiftImport(root.path, candidates);

  // ── 4. Classify entry kind ────────────────────────────────────────────────
  final entry = _classifyEntry(chosen.modulePath, root.path, chosen.baseName);

  return KmpFrameworkModule(
    modulePath: chosen.modulePath,
    moduleName: chosen.moduleName,
    baseName: chosen.baseName,
    entryKind: entry.kind,
    entryClass: entry.entryClass,
    entrySelector: entry.entrySelector,
    swiftAppDir: entry.swiftAppDir,
    swiftSources: entry.swiftSources,
    swiftImports: entry.swiftImports,
  );
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// A parsed include(":gradle:id") entry with both gradle form and disk path.
class _ModuleSpec {
  const _ModuleSpec(this.gradleId, this.diskPath);

  /// Gradle module ID without leading colon; colons preserved for nested
  /// modules. e.g. `shared` or `a:b`. Used for gradle task addressing.
  final String gradleId;

  /// Absolute path to the module directory on disk. e.g. `<root>/a/b`.
  final String diskPath;

  /// Leaf segment — used for init-script `name` guards and klib dir names.
  String get leaf => gradleId.split(':').last;
}

class _Candidate {
  const _Candidate(this.moduleName, this.modulePath, this.baseName);
  final String moduleName;
  final String modulePath;
  final String baseName;
}

class _EntryResult {
  const _EntryResult(
    this.kind, {
    this.entryClass,
    this.entrySelector,
    this.swiftAppDir,
    this.swiftSources,
    this.swiftImports,
  });
  final KmpEntryKind kind;
  final String? entryClass;
  final String? entrySelector;
  final String? swiftAppDir;
  final List<String>? swiftSources;
  final Set<String>? swiftImports;
}

File? _findFile(String dir, List<String> names) {
  for (final name in names) {
    final f = File(p.join(dir, name));
    if (f.existsSync()) return f;
  }
  return null;
}

/// Parse `include(":a")` / `include(":a:b")` lines from settings file.
///
/// Returns [_ModuleSpec] entries carrying both the gradle colon ID (e.g.
/// `shared`, `a:b`) and the absolute disk path (e.g. `<root>/a/b`).
List<_ModuleSpec> _parseIncludedModules(String content, String projectRoot) {
  final result = <_ModuleSpec>[];
  final re = RegExp(r'''include\s*\(\s*["'](:[\w:]+)["']\s*\)''');
  for (final m in re.allMatches(content)) {
    final raw = m.group(1)!; // e.g. ':shared' or ':a:b'
    // Strip leading colon; keep inner colons for gradle task addressing.
    final gradleId = raw.substring(1); // 'shared' or 'a:b'
    // Map to disk path: replace colons with the OS path separator.
    final diskPath =
        p.join(projectRoot, gradleId.replaceAll(':', p.separator));
    result.add(_ModuleSpec(gradleId, diskPath));
  }
  return result;
}

bool _hasIosArm64(String content) {
  return RegExp(r'iosArm64\s*[({]').hasMatch(content) ||
      content.contains('iosArm64()');
}

bool _hasFrameworkBlock(String content) {
  return content.contains('binaries.framework');
}

/// Returns the explicit baseName from `baseName = "Foo"`, or null.
String? _extractBaseName(String content) {
  final m = RegExp(r'baseName\s*=\s*"([^"]+)"').firstMatch(content);
  return m?.group(1);
}

String _capitalize(String s) {
  if (s.isEmpty) return s;
  // Use the leaf segment only (handles nested like 'a/b' → 'b').
  final name = p.basename(s);
  return name[0].toUpperCase() + name.substring(1);
}

/// Pick a candidate by scanning iosApp/**/*.swift for `import <baseName>`.
_Candidate _pickBySwiftImport(String projectRoot, List<_Candidate> candidates) {
  final iosAppDir = Directory(p.join(projectRoot, 'iosApp'));
  if (!iosAppDir.existsSync()) return candidates.first;

  final swiftFiles = iosAppDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.swift'));

  for (final sf in swiftFiles) {
    final source = sf.readAsStringSync();
    for (final c in candidates) {
      if (source.contains('import ${c.baseName}')) return c;
    }
  }
  // Fallback: first candidate
  return candidates.first;
}

// ---------------------------------------------------------------------------
// Entry classification
// ---------------------------------------------------------------------------

/// Allowed system-framework imports for [KmpEntryKind.swiftApp] detection.
/// If any `import X` in swiftSources is outside this set ∪ {baseName}, the
/// project is not classified as swiftApp (an SPM/CocoaPods dep would fail the
/// Linux swiftc build).
const _allowedSwiftImports = {
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

/// Classify the entry kind for the chosen module.
///
/// Phase-1 precedence:
///   1. If SwiftUI host (`@main : App`) exists in iosApp AND no Kotlin UI
///      entry in iosMain → [KmpEntryKind.swiftApp].
///   2. If Kotlin UI entry exists → [KmpEntryKind.runnableApp] (ObjC path).
///   3. Otherwise → [KmpEntryKind.frameworkOnly].
///
/// Phase 2 (TODO): swiftApp will win even when a Kotlin entry is present.
_EntryResult _classifyEntry(
    String modulePath, String projectRoot, String baseName) {
  // ── A. Scan iosMain for Kotlin UI entry ───────────────────────────────────
  final kotlinEntry = _detectKotlinEntry(modulePath);

  // ── B. Scan iosApp for SwiftUI host ───────────────────────────────────────
  final swiftResult = _detectSwiftAppEntry(projectRoot, baseName);

  // ── C. Phase-1 precedence ─────────────────────────────────────────────────
  if (swiftResult != null && kotlinEntry == null) {
    // SwiftUI host present, no Kotlin entry → swiftApp.
    return swiftResult;
  }
  if (kotlinEntry != null) {
    // Kotlin entry present → runnableApp (ObjC path).
    return kotlinEntry;
  }
  // Neither → frameworkOnly.
  return const _EntryResult(KmpEntryKind.frameworkOnly);
}

/// Scan `<modulePath>/src/iosMain/**/*.kt` for a Compose UI entry.
///
/// Returns null if not found; returns an [_EntryResult] with
/// [KmpEntryKind.runnableApp] if found.
_EntryResult? _detectKotlinEntry(String modulePath) {
  final iosMainDir = Directory(p.join(modulePath, 'src', 'iosMain'));
  if (!iosMainDir.existsSync()) return null;

  final ktFiles = iosMainDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.kt'));

  final composePattern = RegExp('ComposeUIViewController');
  final funUiVcPattern = RegExp(
    r'fun\s+([A-Z][A-Za-z0-9_]*)\s*\([^)]*\)\s*(?::\s*UIViewController\b|=\s*ComposeUIViewController\b)',
  );

  for (final f in ktFiles) {
    final source = f.readAsStringSync();
    if (!composePattern.hasMatch(source) && !funUiVcPattern.hasMatch(source)) {
      continue;
    }

    final m = funUiVcPattern.firstMatch(source);
    if (m != null) {
      final funcName = m.group(1)!;
      final ktBasename = p.basenameWithoutExtension(f.path);
      return _EntryResult(
        KmpEntryKind.runnableApp,
        entryClass: '${ktBasename}Kt',
        entrySelector: funcName,
      );
    }

    // ComposeUIViewController used but fun pattern not matched — infer from file.
    final ktBasename = p.basenameWithoutExtension(f.path);
    return _EntryResult(
      KmpEntryKind.runnableApp,
      entryClass: '${ktBasename}Kt',
      entrySelector: ktBasename,
    );
  }
  return null;
}

/// Scan `<projectRoot>/iosApp/**/*.swift` for a SwiftUI `@main : App` host.
///
/// Returns null if:
///   - no `@main` + `: App` file found, OR
///   - import gate fails (foreign module → would fail Linux swiftc build).
///
/// When successful returns an [_EntryResult] with [KmpEntryKind.swiftApp] and
/// the populated [_EntryResult.swiftAppDir], [_EntryResult.swiftSources], and
/// [_EntryResult.swiftImports] fields.
_EntryResult? _detectSwiftAppEntry(String projectRoot, String baseName) {
  final iosAppDir = Directory(p.join(projectRoot, 'iosApp'));
  if (!iosAppDir.existsSync()) return null;

  // Collect all .swift files, applying exclusions.
  final allSwift = iosAppDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.swift') && !_excludeSwiftPath(f.path))
      .toList();

  if (allSwift.isEmpty) return null;

  // Find the file with @main AND : App conformance.
  final mainPattern = RegExp('@main');
  final appConformancePattern = RegExp(r':\s*App\b');

  File? mainFile;
  for (final f in allSwift) {
    final src = f.readAsStringSync();
    if (mainPattern.hasMatch(src) && appConformancePattern.hasMatch(src)) {
      mainFile = f;
      break;
    }
  }
  if (mainFile == null) return null;

  // swiftAppDir = directory containing the @main file.
  final swiftAppDir = p.dirname(mainFile.path);

  // swiftSources = all .swift files under swiftAppDir (apply same exclusions).
  final swiftSources = Directory(swiftAppDir)
      .listSync(recursive: true)
      .whereType<File>()
      .where(
          (f) => f.path.endsWith('.swift') && !_excludeSwiftPath(f.path))
      .map((f) => f.path)
      .toList()
    ..sort();

  // swiftImports = union of all `import X` from swiftSources.
  final importRe = RegExp(r'^import\s+(\w+)', multiLine: true);
  final swiftImports = <String>{};
  for (final src in swiftSources) {
    final content = File(src).readAsStringSync();
    for (final m in importRe.allMatches(content)) {
      swiftImports.add(m.group(1)!);
    }
  }

  // Import gate: reject if any import is outside allowed ∪ {baseName}.
  final allowed = {..._allowedSwiftImports, baseName};
  final foreign = swiftImports.where((imp) => !allowed.contains(imp)).toSet();
  if (foreign.isNotEmpty) {
    // Foreign modules would fail Linux swiftc — fall back.
    return null;
  }

  return _EntryResult(
    KmpEntryKind.swiftApp,
    swiftAppDir: swiftAppDir,
    swiftSources: swiftSources,
    swiftImports: swiftImports,
  );
}

/// Returns true if [path] should be excluded from the Swift source list.
///
/// Excluded path SEGMENTS (not file names):
///   - `Preview Content` — Xcode preview asset bundles (not compilable on Linux)
///   - segments ending in `Tests` or `UITests` — test targets
bool _excludeSwiftPath(String path) {
  for (final segment in path.split(p.separator)) {
    if (segment == 'Preview Content') return true;
    if (segment.endsWith('Tests') || segment.endsWith('UITests')) return true;
  }
  return false;
}
