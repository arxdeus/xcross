import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/build/ios_plugins.dart';
import 'package:xcross/src/flutter/build/swift_package_host_patches.dart';
import 'package:xcross/src/flutter/constants.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmManifest<T extends PlatformHostInterface> {
  SwiftPmManifest(this.runtime);
  final SwiftPmRuntime<T> runtime;

  /// `FlutterFramework/Package.swift` contents — wraps `Flutter.xcframework`
  /// as a SwiftPM binary target.
  static String flutterFrameworkManifest() =>
      '''
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "$flutterFrameworkPackageName",
    products: [
        .library(name: "$flutterFrameworkPackageName", targets: ["$flutterFrameworkPackageName"])
    ],
    targets: [
        .binaryTarget(name: "$flutterFrameworkPackageName", path: "Flutter.xcframework")
    ]
)
''';

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

  static String removeMissingResources(String manifest, String packageDir) {
    final targets = SwiftPmManifest.swiftCalls(manifest, '.target');
    final resourcePattern = RegExp(
      r'\.((?:process|copy))\(\s*"([^"]+)"\s*\)\s*,?',
    );
    var result = manifest;
    for (final match
        in resourcePattern.allMatches(manifest).toList().reversed) {
      var root = packageDir;
      for (final target in targets) {
        if (target.start > match.start || target.end < match.end) continue;
        final explicitPath = SwiftPmManifest.namedString(target.text, 'path');
        final name = SwiftPmManifest.namedString(target.text, 'name');
        if (explicitPath != null) {
          root = p.joinAll([packageDir, ...explicitPath.split('/')]);
        } else if (name != null) {
          root = p.join(packageDir, 'Sources', name);
        }
        break;
      }
      final resource = p.joinAll([root, ...match.group(2)!.split('/')]);
      if (FileSystemEntity.typeSync(resource) ==
          FileSystemEntityType.notFound) {
        result = result.replaceRange(match.start, match.end, '');
      }
    }
    return result;
  }

  /// Host-side Package.swift fixes for cross builds.
  ///
  /// Includes [normalizeLinkerFlags], plus Windows Swift 6+ CRT imports so
  /// manifests that call `getenv` via removed `MSVCRT` (notably sentry-cocoa)
  /// still compile on the host, and drops the Foundation-only
  /// `String(cString:encoding:)` overload that manifests cannot use.
  String normalizeHostManifest(String manifest) {
    var result = SwiftPmManifest.normalizeLinkerFlags(manifest);
    // sentry-cocoa and similar: Darwin/Glibc/MSVCRT — MSVCRT was replaced by
    // CRT on Windows Swift 6 (https://github.com/apple/swift/pull/34299).
    final beforeCrtNormalization = result;
    result = result.replaceAllMapped(
      RegExp(r'#elseif\s+canImport\(MSVCRT\)\r?\nimport MSVCRT'),
      (match) {
        final prefix = beforeCrtNormalization.substring(0, match.start);
        if (prefix.endsWith(
          '#elseif canImport(CRT)\n'
          'import CRT\n'
          '#elseif canImport(ucrt)\n'
          'import ucrt\n',
        )) {
          return match.group(0)!;
        }
        return '#elseif canImport(CRT)\n'
            'import CRT\n'
            '#elseif canImport(ucrt)\n'
            'import ucrt\n'
            '#elseif canImport(MSVCRT)\n'
            'import MSVCRT';
      },
    );
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
    final importCode = SwiftPmManifest.swiftCodeMask(source);
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
    if (FileSystemEntity.typeSync(root, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    final files = <File>[];

    Future<void> collect(String directory) async {
      await for (final entity in Directory(
        directory,
      ).list(followLinks: false)) {
        final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          await collect(entity.path);
        } else if (type == FileSystemEntityType.file &&
            p.extension(entity.path) == '.swift') {
          final name = p.basename(entity.path);
          if (name != 'Package.swift' &&
              !(name.startsWith('Package@') && name.endsWith('.swift'))) {
            files.add(File(entity.path));
          }
        }
      }
    }

    await collect(root);
    final changes = <File, String>{};
    for (final file in files) {
      final original = await file.readAsString();
      final normalized = SwiftPmManifest.normalizeHostSwiftSource(
        original,
        fallbackSwiftModules: fallbackSwiftModules,
      );
      if (normalized != original) changes[file] = normalized;
    }
    for (final change in changes.entries) {
      await change.key.writeAsString(change.value);
    }
  }

  static List<bool> swiftCodeMask(String source) {
    final code = List<bool>.filled(source.length, true);
    var i = 0;
    while (i < source.length) {
      if (source.startsWith('//', i)) {
        final end = source.indexOf('\n', i + 2);
        final limit = end < 0 ? source.length : end;
        for (; i < limit; i++) {
          code[i] = false;
        }
        continue;
      }
      if (source.startsWith('/*', i)) {
        var depth = 0;
        do {
          if (source.startsWith('/*', i)) {
            depth++;
            code[i++] = false;
            if (i < source.length) code[i++] = false;
          } else if (source.startsWith('*/', i)) {
            depth--;
            code[i++] = false;
            if (i < source.length) code[i++] = false;
          } else {
            code[i++] = false;
          }
        } while (i < source.length && depth > 0);
        continue;
      }

      var hashes = 0;
      while (i + hashes < source.length && source[i + hashes] == '#') {
        hashes++;
      }
      final quote = i + hashes;
      if (quote < source.length &&
          source[quote] == '"' &&
          (hashes == 0 || quote > i)) {
        final quotes = source.startsWith('"""', quote) ? 3 : 1;
        final delimiter =
            '${quotes == 3 ? '"""' : '"'}${List.filled(hashes, '#').join()}';
        var cursor = quote + quotes;
        while (cursor < source.length) {
          if (source.startsWith(delimiter, cursor)) {
            cursor += delimiter.length;
            break;
          }
          if (hashes == 0 && source[cursor] == r'\') {
            cursor += 2;
          } else {
            cursor++;
          }
        }
        final end = cursor.clamp(0, source.length);
        for (var j = i; j < end; j++) {
          code[j] = false;
        }
        i = end;
        continue;
      }
      i++;
    }
    return code;
  }

  Future<Map<String, String>> packageIdentitiesByDirectory(String root) async {
    final identities = <String, String>{};
    final pending = <String>[root];
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final directory = p.normalize(pending.removeLast());
      if (!visited.add(directory)) continue;
      final manifestFile = File(p.join(directory, 'Package.swift'));
      if (!manifestFile.existsSync()) continue;
      final manifest = await manifestFile.readAsString();
      for (final call in SwiftPmManifest.swiftCalls(manifest, '.package')) {
        final path = SwiftPmManifest.namedString(call.text, 'path');
        if (path == null) continue;
        final dependencyDirectory = p.normalize(
          p.isAbsolute(path) ? path : p.join(directory, path),
        );
        final dependencyManifest = File(
          p.join(dependencyDirectory, 'Package.swift'),
        );
        final identity =
            SwiftPmManifest.namedString(call.text, 'name') ??
            (dependencyManifest.existsSync()
                ? RegExp(r'Package\s*\(\s*name\s*:\s*"([^"]+)"')
                      .firstMatch(await dependencyManifest.readAsString())
                      ?.group(1)
                : null);
        if (identity != null) identities[dependencyDirectory] = identity;
        pending.add(dependencyDirectory);
      }
    }
    return identities;
  }

  /// Parses remote `.package(url:)` entries out of a Swift manifest.
  ///
  /// Uses parenthesis balancing so nested forms like
  /// `.upToNextMajor(from: "1.0.0")` are not truncated at the inner `)`.
  static List<SwiftPmPackageDependency> parseUrlPackageDeps(String manifest) {
    final deps = <SwiftPmPackageDependency>[];
    final constants = SwiftPmManifest.manifestStringConstants(manifest);
    var searchFrom = 0;
    final startPattern = RegExp(r'\.package\s*\(');
    while (true) {
      final startMatch = startPattern
          .allMatches(manifest, searchFrom)
          .firstOrNull;
      if (startMatch == null) break;
      final start = startMatch.start;
      final open = startMatch.end - 1; // '('
      final close = SwiftPmManifest.indexOfMatchingParen(manifest, open);
      if (close < 0) break;
      final inner = manifest.substring(open + 1, close);
      final urlMatch = RegExp(
        r'url:\s*(?:"(?<literal>[^"]+)"|(?<constant>[A-Za-z_]\w*)\b(?!\s*\.))',
      ).firstMatch(inner);
      final url =
          urlMatch?.namedGroup('literal') ??
          constants[urlMatch?.namedGroup('constant')];
      if (url == null) {
        searchFrom = close + 1;
        continue;
      }
      final nameMatch = RegExp(r'name:\s*"(?<name>[^"]*)"').firstMatch(inner);
      final name = nameMatch?.namedGroup('name');
      deps.add(
        SwiftPmPackageDependency(
          name: name,
          url: url,
          identity: name ?? SwiftPmManifest.packageIdentityFromUrl(url),
          match: manifest.substring(start, close + 1),
        ),
      );
      searchFrom = close + 1;
    }
    return deps;
  }

  /// `let name = "..."` string constants, so `.package(url: name, ...)`
  /// (firebase-ios-sdk's `appMeasurementURL`) can be vendored like literals.
  static Map<String, String> manifestStringConstants(String manifest) {
    final pattern = RegExp(
      r'\b(?:let|var)\s+(?<name>[A-Za-z_]\w*)\s*(?::\s*[\w.<>]+)?\s*=\s*"(?<value>[^"\r\n]*)"',
    );
    return {
      for (final match in pattern.allMatches(manifest))
        match.namedGroup('name')!: match.namedGroup('value')!,
    };
  }

  /// Index of the `)` that closes the `(` at [openIndex], or -1.
  static int indexOfMatchingParen(String source, int openIndex) {
    var depth = 0;
    var inString = false;
    for (var i = openIndex; i < source.length; i++) {
      final c = source[i];
      if (inString) {
        if (c == r'\' && i + 1 < source.length) {
          i++;
          continue;
        }
        if (c == '"') inString = false;
        continue;
      }
      if (c == '"') {
        inString = true;
        continue;
      }
      if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  /// Folder name for a vendored checkout of [url] at [ref].
  static String vendorPackageDirName(String url, String ref) {
    final safeRef = ref.replaceAll(RegExp(r'[^\w.\-]+'), '_');
    final identity = SwiftPmManifest.packageIdentityFromUrl(url);
    if (identity == 'firebase-ios-sdk') {
      return 'fb@${safeRef.length > 12 ? safeRef.substring(0, 12) : safeRef}';
    }
    return '$identity@$safeRef';
  }

  /// Swift tools version declared by [manifest], or `null` when absent.
  ///
  /// `.package(name:path:)` only exists from PackageDescription 5.2, so a
  /// vendored manifest older than that (SDWebImageWebPCoder pins 5.0) must
  /// get a plain `.package(path:)`. Pre-5.2 SwiftPM derives the dependency
  /// name from the dependency's own `Package(name:)`, so target references
  /// keep resolving without an explicit `name:`.
  static ({int major, int minor})? manifestToolsVersion(String manifest) {
    final match = RegExp(
      r'^//\s*swift-tools-version\s*:?\s*(\d+)(?:\.(\d+))?',
      multiLine: true,
    ).firstMatch(manifest);
    if (match == null) return null;
    return (
      major: int.parse(match.group(1)!),
      minor: int.tryParse(match.group(2) ?? '0') ?? 0,
    );
  }

  static bool supportsNamedPathDeps(String manifest) {
    final version = SwiftPmManifest.manifestToolsVersion(manifest);
    if (version == null) return true;
    return version.major > 5 || (version.major == 5 && version.minor >= 2);
  }

  /// SwiftPM package identity implied by a git URL (last path segment, no
  /// `.git`). Used as `.package(name:)` so target `package:` references keep
  /// matching after we vendor into a `name@version` directory.
  static String packageIdentityFromUrl(String url) {
    var identity = Uri.parse(url).pathSegments.lastWhere(
      (segment) => segment.isNotEmpty,
      orElse: () => 'package',
    );
    if (identity.endsWith('.git')) {
      identity = identity.substring(0, identity.length - 4);
    }
    return identity;
  }

  static List<({int start, int end, String text})> swiftCalls(
    String source,
    String name,
  ) {
    final calls = <({int start, int end, String text})>[];
    final pattern = RegExp('${RegExp.escape(name)}\\s*\\(');
    for (final match in pattern.allMatches(source)) {
      final close = SwiftPmManifest.indexOfMatchingParen(source, match.end - 1);
      if (close >= 0) {
        calls.add((
          start: match.start,
          end: close + 1,
          text: source.substring(match.start, close + 1),
        ));
      }
    }
    return calls;
  }

  static String? namedString(String call, String name) =>
      RegExp('${RegExp.escape(name)}\\s*:\\s*"([^"]+)"').firstMatch(call)?[1];

  static List<String> namedStringList(String call, String name) {
    final argument = RegExp('${RegExp.escape(name)}\\s*:').firstMatch(call);
    if (argument == null) return const [];
    final open = call.indexOf('[', argument.end);
    if (open < 0) return const [];
    final close = SwiftPmManifest.indexOfMatchingDelimiter(call, open);
    if (close < 0) return const [];
    return [
      for (final match in RegExp(
        '"([^"]+)"',
      ).allMatches(call.substring(open + 1, close)))
        match[1]!,
    ];
  }

  static int indexOfMatchingDelimiter(String source, int openIndex) {
    final open = source[openIndex];
    final close = switch (open) {
      '(' => ')',
      '[' => ']',
      '{' => '}',
      _ => '',
    };
    if (close.isEmpty) return -1;
    final code = SwiftPmManifest.swiftCodeMask(source);
    var depth = 0;
    for (var i = openIndex; i < source.length; i++) {
      if (!code[i]) continue;
      if (source[i] == open) {
        depth++;
      } else if (source[i] == close && --depth == 0) {
        return i;
      }
    }
    return -1;
  }

  static ({int open, int close})? fallbackBlock(String manifest) {
    final marker = manifest.indexOf('products.removeAll()');
    if (marker < 0) return null;
    final open = manifest.lastIndexOf('{', marker);
    if (open < 0) return null;
    final close = SwiftPmManifest.indexOfMatchingDelimiter(manifest, open);
    return close < 0 ? null : (open: open, close: close);
  }

  static Set<String> consumedProducts(String manifest, String package) {
    final products = <String>{};
    for (final call in SwiftPmManifest.swiftCalls(manifest, '.product')) {
      if (SwiftPmManifest.namedString(call.text, 'package') == package) {
        final name = SwiftPmManifest.namedString(call.text, 'name');
        if (name != null) products.add(name);
      }
    }
    return products;
  }

  static List<String> topLevelModuleNames(String moduleMap) {
    final code = SwiftPmManifest.swiftCodeMask(moduleMap);
    final names = <String>[];
    var depth = 0;
    var lineStart = 0;
    for (var i = 0; i <= moduleMap.length; i++) {
      if (i == moduleMap.length || moduleMap[i] == '\n') {
        if (depth == 0) {
          final line = moduleMap.substring(lineStart, i);
          final match = RegExp(
            r'^\s*(?:(?:framework|explicit)\s+)?module\s+'
            r'([A-Za-z_][A-Za-z0-9_]*)\s*\{',
          ).firstMatch(line);
          if (match != null) names.add(match[1]!);
        }
        for (var j = lineStart; j < i; j++) {
          if (!code[j]) continue;
          if (moduleMap[j] == '{') depth++;
          if (moduleMap[j] == '}') depth--;
        }
        lineStart = i + 1;
      }
    }
    return names;
  }

  static ({int start, int open, int close})? moduleBlock(
    String moduleMap,
    String name,
  ) {
    final declaration = RegExp(
      r'^\s*(?:(?:framework|explicit)\s+)?module\s+'
      '${RegExp.escape(name)}\\s*\\{',
      multiLine: true,
    ).firstMatch(moduleMap);
    if (declaration == null) return null;
    final open = moduleMap.indexOf('{', declaration.start);
    final close = SwiftPmManifest.indexOfMatchingDelimiter(moduleMap, open);
    return close < 0
        ? null
        : (start: declaration.start, open: open, close: close);
  }

  static List<({String path, bool directory})> directModuleHeaders(
    String moduleMap,
    ({int start, int open, int close}) block,
  ) {
    final code = SwiftPmManifest.swiftCodeMask(moduleMap);
    final headers = <({String path, bool directory})>[];
    var depth = 1;
    var lineStart = block.open + 1;
    for (var i = block.open + 1; i <= block.close; i++) {
      if (i != block.close && moduleMap[i] != '\n') continue;
      final line = moduleMap.substring(lineStart, i);
      if (depth == 1) {
        final header = RegExp(
          r'^\s*(?:umbrella\s+)?header\s+"([^"]+)"',
        ).firstMatch(line);
        final umbrella = RegExp(r'^\s*umbrella\s+"([^"]+)"').firstMatch(line);
        if (header != null) {
          headers.add((path: header[1]!, directory: false));
        } else if (umbrella != null) {
          headers.add((path: umbrella[1]!, directory: true));
        }
      }
      for (var j = lineStart; j < i; j++) {
        if (!code[j]) continue;
        if (moduleMap[j] == '{') depth++;
        if (moduleMap[j] == '}') depth--;
      }
      lineStart = i + 1;
    }
    return headers;
  }

  static int braceDepthAt(String source, int offset) {
    final code = SwiftPmManifest.swiftCodeMask(source);
    var depth = 0;
    for (var i = 0; i < offset; i++) {
      if (!code[i]) continue;
      if (source[i] == '{') depth++;
      if (source[i] == '}') depth--;
    }
    return depth;
  }

  static List<String> directNestedModules(
    String moduleMap,
    ({int start, int open, int close}) parent,
  ) {
    final nested = <String>[];
    final declaration = RegExp(
      r'^\s*(?:(?:framework|explicit)\s+)?module\s+'
      r'[A-Za-z_][A-Za-z0-9_]*\s*\{',
      multiLine: true,
    );
    for (final match in declaration.allMatches(moduleMap, parent.open + 1)) {
      if (match.start >= parent.close) break;
      if (SwiftPmManifest.braceDepthAt(moduleMap, match.start) != 1) continue;
      final open = moduleMap.indexOf('{', match.start);
      final close = SwiftPmManifest.indexOfMatchingDelimiter(moduleMap, open);
      if (close < 0 || close > parent.close) continue;
      nested.add(moduleMap.substring(match.start, close + 1).trim());
    }
    return nested;
  }

  static bool ignoredPackageEvidencePath(String packageDir, String path) {
    final relative = p.relative(path, from: packageDir);
    final parts = p.split(relative);
    return parts.any(
      (part) => part == '.git' || part == '.build' || part == '.xcross',
    );
  }

  static String resolveModuleReference(
    String packageDir,
    String reference, {
    required bool directory,
  }) {
    final normalized = p.normalize(reference);
    final matches = <String>[];
    for (final entity in Directory(
      packageDir,
    ).listSync(recursive: true, followLinks: false)) {
      if (SwiftPmManifest.ignoredPackageEvidencePath(packageDir, entity.path)) {
        continue;
      }
      if (directory ? entity is! Directory : entity is! File) continue;
      final relative = p.normalize(p.relative(entity.path, from: packageDir));
      if (relative == normalized ||
          relative.endsWith('${p.separator}$normalized') ||
          p.basename(relative) == p.basename(normalized)) {
        matches.add(entity.path);
      }
    }
    if (matches.length != 1) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM module: ${directory ? 'directory' : 'header'} '
        '"$reference" has ${matches.length} matches in $packageDir.',
      );
    }
    return p.normalize(p.absolute(matches.single));
  }

  static String absoluteNestedModuleHeaders(String packageDir, String nested) {
    final result = nested.replaceAllMapped(
      RegExp(r'((?:umbrella\s+)?header\s+)"([^"]+)"'),
      (match) {
        final resolved = SwiftPmManifest.resolveModuleReference(
          packageDir,
          match[2]!,
          directory: false,
        );
        return '${match[1]}"${SwiftPmFilesystem.swiftPath(resolved)}"';
      },
    );
    return result.replaceAllMapped(RegExp(r'(umbrella\s+)"([^"]+)"'), (match) {
      final resolved = SwiftPmManifest.resolveModuleReference(
        packageDir,
        match[2]!,
        directory: true,
      );
      return '${match[1]}"${SwiftPmFilesystem.swiftPath(resolved)}"';
    });
  }

  /// `Plugins/Package.swift` contents — aggregates every plugin's SPM package
  /// into one dynamic library product depending on [frameworkDir]'s
  /// `FlutterFramework` package plus every entry in [plugins].
  static String pluginsManifest(
    List<IosPlugin> plugins,
    String frameworkDir, {
    required IosDeploymentTarget deploymentTarget,
    Map<String, String>? pluginPackageDirs,
  }) {
    final dependencies = StringBuffer()
      ..writeln(
        '        .package(name: "$flutterFrameworkPackageName", '
        'path: "${SwiftPmFilesystem.swiftPath(frameworkDir)}"),',
      );
    for (final plugin in plugins) {
      final packageDir =
          pluginPackageDirs?[plugin.name] ?? plugin.swiftPackageDir;
      dependencies.writeln(
        '        .package(name: "${plugin.name}", '
        'path: "${SwiftPmFilesystem.swiftPath(packageDir)}"),',
      );
    }

    final targetDependencies = StringBuffer()
      ..writeln(
        '                .product(name: "$flutterFrameworkPackageName", '
        'package: "$flutterFrameworkPackageName"),',
      );
    for (final plugin in plugins) {
      targetDependencies.writeln(
        '                .product(name: "${SwiftPmFilesystem.hyphenate(plugin.name)}", '
        'package: "${plugin.name}"),',
      );
    }

    return '''
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "$pluginsProductName",
    platforms: [
        .iOS("${deploymentTarget.version}")
    ],
    products: [
        .library(name: "$pluginsProductName", type: .dynamic, targets: ["$pluginsProductName"])
    ],
    dependencies: [
$dependencies    ],
    targets: [
        .target(
            name: "$pluginsProductName",
            dependencies: [
$targetDependencies            ]
        )
    ]
)
''';
  }

  /// `GeneratedPluginRegistrant.swift` contents — imports and registers each
  /// plugin that has a non-null `pluginClassIos`. Plugins with no class
  /// (facade/pure-Dart/FFI-only packages) remain SwiftPM target dependencies,
  /// but need no module import or registration call.
  String registrantSource(
    List<IosPlugin> plugins, {
    bool verbose = false,
    Map<String, String> stagedPackageDirs = const {},
  }) {
    final imports = StringBuffer();
    final registrations = StringBuffer();
    var pluginCount = 0;
    for (final plugin in plugins) {
      final pluginClass = plugin.pluginClassIos;
      if (pluginClass == null) continue;
      pluginCount++;
      imports.writeln('import ${plugin.name}');
      final registration = StringBuffer();
      if (verbose) {
        registration.writeln('''
    NSLog("[xcross] registering plugin ${plugin.name} ($pluginClass)")
    if let registrar = registry.registrar(forPlugin: "$pluginClass") {
        $pluginClass.register(with: registrar)
        registered += 1
        NSLog("[xcross] registered plugin ${plugin.name} ($pluginClass)")
    } else {
        failures.append("${plugin.name} ($pluginClass): registrar unavailable")
        NSLog("[xcross] failed plugin ${plugin.name} ($pluginClass): registrar unavailable")
    }''');
      } else {
        registration.writeln('''
    if let registrar = registry.registrar(forPlugin: "$pluginClass") {
        $pluginClass.register(with: registrar)
    }''');
      }
      final availableFrom = plugin.pluginClassIosAvailabilityIn(
        policy: runtime.targetPolicy,
        stagedPackage: stagedPackageDirs[plugin.name],
      );
      if (availableFrom == null) {
        registrations.write(registration);
      } else {
        registrations.writeln('''
    if #available(iOS $availableFrom, *) {''');
        registrations.write(registration);
        registrations.writeln('    } else {');
        if (verbose) {
          registrations.writeln(
            '''
        failures.append("${plugin.name} ($pluginClass): requires iOS $availableFrom")
        NSLog("[xcross] skipped plugin ${plugin.name} ($pluginClass): requires iOS $availableFrom")''',
          );
        }
        registrations.writeln('    }');
      }
    }

    final diagnosticsStart = verbose
        ? '    var registered = 0\n'
              '    var failures: [String] = []\n'
        : '';
    final diagnosticsEnd = verbose
        ? '    NSLog("[xcross] plugin registration summary: '
              '$pluginCount attempted, \\(registered) registered, '
              '\\(failures.count) failed")\n'
              '    for failure in failures {\n'
              '        NSLog("[xcross] plugin registration failure: '
              '\\(failure)")\n'
              '    }\n'
        : '';

    return '''
//
// Generated file. Do not edit.
//
import Flutter
import UIKit
$imports
@_cdecl("${GeneratedPluginsConstants.registrantSymbol}")
public func xcrossRegisterGeneratedPlugins(_ registry: FlutterPluginRegistry) {
$diagnosticsStart$registrations$diagnosticsEnd}
''';
  }
}
