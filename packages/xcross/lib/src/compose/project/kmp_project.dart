import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/project/ios_app_config.dart';
import 'package:xcross/src/errors.dart';

enum KmpEntryKind { runnableApp, swiftApp, frameworkOnly }

final class KmpProject {
  const KmpProject({
    required this.root,
    required this.modulePath,
    required this.moduleName,
    required this.baseName,
    required this.entryKind,
    required this.bundleId,
    required this.appName,
    this.isStaticFramework = false,
    this.entryClass,
    this.entrySelector,
    this.swiftAppDir,
    this.swiftSources = const [],
    this.swiftImports = const {},
    this.iosConfig,
  });

  final String root;
  final String modulePath;
  final String moduleName;
  final String baseName;
  final KmpEntryKind entryKind;

  /// `binaries.framework { isStatic = true }` in the module's build script.
  /// The framework link must pass `-Xstatic-framework`, otherwise Kotlin/Native
  /// produces a dynamic library and the link then requires every ObjC
  /// dependency of the module (Firebase, system libraries) to be resolvable.
  final bool isStaticFramework;
  final String bundleId;
  final String appName;
  final String? entryClass;
  final String? entrySelector;
  final String? swiftAppDir;
  final List<String> swiftSources;
  final Set<String> swiftImports;
  final IosAppConfig? iosConfig;

  String get moduleLeaf => moduleName.split(':').last;

  static KmpProject detect(String root, {String? bundleId, String? appName}) =>
      _KmpProjectDetector(
        root: root,
        bundleIdOverride: bundleId,
        appNameOverride: appName,
      ).detect();
}

final class _KmpProjectDetector {
  const _KmpProjectDetector({
    required this.root,
    this.bundleIdOverride,
    this.appNameOverride,
  });

  final String root;
  final String? bundleIdOverride;
  final String? appNameOverride;

  KmpProject detect() {
    final rootDir = Directory(root);
    if (!rootDir.existsSync()) {
      throw XcrossError('KMP project root not found: $root');
    }
    final settings = _findFile(root, [
      'settings.gradle.kts',
      'settings.gradle',
    ]);
    if (settings == null) {
      throw XcrossError(
        'No settings.gradle.kts found in $root. Is this a Gradle KMP project?',
      );
    }
    final modules = _parseIncludedModules(settings.readAsStringSync(), root);
    if (modules.isEmpty) {
      throw XcrossError('No included modules found in ${settings.path}.');
    }

    final candidates = <_Candidate>[];
    for (final module in modules) {
      final buildFile = _findFile(module.diskPath, [
        'build.gradle.kts',
        'build.gradle',
      ]);
      if (buildFile == null) continue;
      final content = buildFile.readAsStringSync();
      if (!_hasIosArm64(content) || !_hasFrameworkBlock(content)) continue;
      candidates.add(
        _Candidate(
          module.gradleId,
          module.diskPath,
          _extractBaseName(content) ?? _capitalize(module.leaf),
          isStaticFramework: _extractIsStaticFramework(content),
        ),
      );
    }
    if (candidates.isEmpty) {
      throw XcrossError(
        'No KMP module with iosArm64() + binaries.framework found in $root. Check your build.gradle.kts files.',
      );
    }
    final chosen = candidates.length == 1
        ? candidates.first
        : _pickBySwiftImport(root, candidates);
    final entry = _classifyEntry(chosen.modulePath, root, chosen.baseName);
    final iosConfig = IosAppConfig.load(root);
    final defaults = _defaultIdentity(root);
    return KmpProject(
      root: root,
      modulePath: chosen.modulePath,
      moduleName: chosen.moduleName,
      baseName: chosen.baseName,
      entryKind: entry.kind,
      isStaticFramework: chosen.isStaticFramework,
      // An xcconfig that sets only some keys (the bundle id often lives in
      // the Xcode project instead) must not produce an empty identity.
      bundleId:
          bundleIdOverride ??
          _nonEmpty(iosConfig?.bundleId) ??
          defaults.bundleId,
      appName:
          appNameOverride ??
          _nonEmpty(iosConfig?.productName) ??
          defaults.appName,
      entryClass: entry.entryClass,
      entrySelector: entry.entrySelector,
      swiftAppDir: entry.swiftAppDir,
      swiftSources: entry.swiftSources,
      swiftImports: entry.swiftImports,
      iosConfig: iosConfig,
    );
  }
}

final class _ModuleSpec {
  const _ModuleSpec(this.gradleId, this.diskPath);
  final String gradleId;
  final String diskPath;
  String get leaf => gradleId.split(':').last;
}

final class _Candidate {
  const _Candidate(
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

final class _EntryResult {
  const _EntryResult(
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

final class _Identity {
  const _Identity(this.bundleId, this.appName);
  final String bundleId;
  final String appName;
}

File? _findFile(String dir, List<String> names) {
  for (final name in names) {
    final file = File(p.join(dir, name));
    if (file.existsSync()) return file;
  }
  return null;
}

List<_ModuleSpec> _parseIncludedModules(String content, String projectRoot) {
  final result = <_ModuleSpec>[];
  final include = RegExp(
    r'''(?:^|[;\n\r])\s*include\s*(?:\(([^)]*)\)|([^\r\n;]+))''',
    multiLine: true,
  );
  final quotedModule = RegExp(
    "[\"'](:[A-Za-z0-9_.-]+(?::[A-Za-z0-9_.-]+)*)[\"']",
  );
  for (final includeMatch in include.allMatches(content)) {
    final args = includeMatch.group(1) ?? includeMatch.group(2) ?? '';
    for (final moduleMatch in quotedModule.allMatches(args)) {
      final gradleId = moduleMatch.group(1)!.substring(1);
      result.add(
        _ModuleSpec(
          gradleId,
          p.join(projectRoot, gradleId.replaceAll(':', p.separator)),
        ),
      );
    }
  }
  return result;
}

bool _hasIosArm64(String content) =>
    RegExp(r'iosArm64\s*[({]').hasMatch(content) ||
    content.contains('iosArm64()');

bool _hasFrameworkBlock(String content) =>
    content.contains('binaries.framework');

String? _extractBaseName(String content) =>
    RegExp(r'baseName\s*=\s*"([^"]+)"').firstMatch(content)?.group(1);

/// Whether the module's framework is declared static.
///
/// Scoped to the `binaries.framework { … }` block rather than matched across
/// the whole script, because `isStatic` is not unique to it: an `xcframework`
/// block, a second target's framework, or a commented-out line would otherwise
/// all turn it on. Getting this wrong is not symmetric - a false positive stages
/// an app with no framework embedded at all, which only fails once the app is
/// launched on a device.
///
/// Both assignment styles Gradle accepts are recognised (`isStatic = true` in
/// Kotlin DSL, `isStatic.set(true)` via the property API).
bool _extractIsStaticFramework(String content) {
  for (final block in _frameworkBlocks(_stripComments(content))) {
    if (RegExp(
      r'isStatic\s*(?:=\s*true\b|\.set\s*\(\s*true\s*\))',
    ).hasMatch(block)) {
      return true;
    }
    final computed = RegExp(
      r'isStatic\s*(?:=\s*(?!true\b|false\b)|\.set\s*\(\s*(?!true\b|false\b))',
    ).hasMatch(block);
    if (computed) {
      Log.logWarn(
        'isStatic in binaries.framework is not a literal true/false, so xcross '
        'treats the framework as dynamic. Use a literal value if it is static.',
      );
    }
  }
  return false;
}

/// [content] with `//` and `/* */` comments removed, leaving string literals
/// intact.
String _stripComments(String content) {
  final out = StringBuffer();
  var i = 0;
  while (i < content.length) {
    final char = content[i];
    final next = i + 1 < content.length ? content[i + 1] : '';
    if (char == '"') {
      final end = _stringEnd(content, i);
      out.write(content.substring(i, end));
      i = end;
    } else if (char == '/' && next == '/') {
      final end = content.indexOf('\n', i);
      i = end < 0 ? content.length : end;
    } else if (char == '/' && next == '*') {
      final end = content.indexOf('*/', i + 2);
      i = end < 0 ? content.length : end + 2;
      out.write(' ');
    } else {
      out.write(char);
      i++;
    }
  }
  return out.toString();
}

int _stringEnd(String content, int start) {
  if (content.startsWith('"""', start)) {
    final end = content.indexOf('"""', start + 3);
    return end < 0 ? content.length : end + 3;
  }
  for (var i = start + 1; i < content.length; i++) {
    if (content[i] == r'\') {
      i++;
    } else if (content[i] == '"' || content[i] == '\n') {
      return i + 1;
    }
  }
  return content.length;
}

/// The body of every `binaries.framework { … }` block, brace-matched.
///
/// Returns null when the block is absent or its braces do not close, so a script
/// this cannot read is treated as "not static", the safe default.
Iterable<String> _frameworkBlocks(String content) sync* {
  final starts = RegExp(
    r'binaries\.framework\s*(?:\([^)]*\)\s*)?\{',
  ).allMatches(content);
  for (final start in starts) {
    var depth = 0;
    for (var i = start.end - 1; i < content.length; i++) {
      final char = content[i];
      if (char == '{') depth++;
      if (char == '}') {
        depth--;
        if (depth == 0) {
          yield content.substring(start.end, i);
          break;
        }
      }
    }
  }
}

String _capitalize(String value) =>
    value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

_Candidate _pickBySwiftImport(String projectRoot, List<_Candidate> candidates) {
  final iosAppDir = Directory(p.join(projectRoot, 'iosApp'));
  final supported = <_Candidate>{};
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

_EntryResult _classifyEntry(
  String modulePath,
  String projectRoot,
  String baseName,
) {
  final kotlinEntry = _detectKotlinEntry(modulePath);
  final swiftEntry = _detectSwiftAppEntry(projectRoot, baseName);
  if (swiftEntry != null && kotlinEntry == null) return swiftEntry;
  if (kotlinEntry != null) return kotlinEntry;
  return const _EntryResult(KmpEntryKind.frameworkOnly);
}

_EntryResult? _detectKotlinEntry(String modulePath) {
  final iosMain = Directory(p.join(modulePath, 'src', 'iosMain'));
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
    return _EntryResult(
      KmpEntryKind.runnableApp,
      entryClass: '${basename}Kt',
      entrySelector: match?.group(1) ?? basename,
    );
  }
  return null;
}

_EntryResult? _detectSwiftAppEntry(String projectRoot, String baseName) {
  final iosApp = Directory(p.join(projectRoot, 'iosApp'));
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
      Directory(appDir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.swift') && !_excludeSwiftPath(f.path))
          .map((f) => f.path)
          .toList()
        ..sort();
  final imports = <String>{};
  final importRe = RegExp(r'^import\s+(\w+)', multiLine: true);
  for (final source in sources) {
    for (final match in importRe.allMatches(File(source).readAsStringSync())) {
      imports.add(match.group(1)!);
    }
  }
  final allowed = {..._allowedSwiftImports, baseName};
  if (imports.any((import) => !allowed.contains(import))) return null;
  return _EntryResult(
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

_Identity _defaultIdentity(String root) {
  final rawName = p.basename(root);
  final words = RegExp(
    '[A-Za-z0-9]+',
  ).allMatches(rawName).map((m) => m.group(0)!).toList();
  final appName = words.isEmpty ? 'Kmp App' : words.join(' ');
  final bundleLeaf = words.join().toLowerCase();
  return _Identity(
    'com.example.${bundleLeaf.isEmpty ? 'kmpapp' : bundleLeaf}',
    appName,
  );
}

String? _nonEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;
