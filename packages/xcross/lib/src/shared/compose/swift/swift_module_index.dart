import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// The set of module names `swiftc` can resolve for `import X` when it is
/// pointed at a Darwin SDK and the toolchain resource dir.
///
/// A hardcoded allowlist of "known good" imports silently rots, so the answer
/// comes from the SDK itself. Everything here is plain filesystem inspection
/// (no process spawning), so it is deterministic and works on any host.
@internal
final class SwiftModuleIndex {
  SwiftModuleIndex._(Set<String> modules, Map<String, String> details)
    : implementationDetailOf = Map.unmodifiable(details),
      modules = Set.unmodifiable(modules.difference(details.keys.toSet()));

  /// Indexes [sdkPath] (the `.sdk` leaf) and [resourceDir] (the toolchain
  /// `usr/lib/swift`). [platformSdkName] is `iphoneos` or `iphonesimulator`.
  /// Missing directories are tolerated and simply contribute nothing.
  factory SwiftModuleIndex.scan({
    required HostFileSystemInterface files,
    required String sdkPath,
    required String resourceDir,
    required String platformSdkName,
    Iterable<String> extraModules = const [],
  }) {
    final found = <String>{...extraModules};
    final details = <String, String>{};

    // Frameworks are importable only when they ship a Modules dir. Headers-only
    // frameworks (e.g. IOKit) are not modules. Foundation, SwiftUI and UIKit
    // live here and have no usr/lib/swift entry.
    for (final sub in const ['Frameworks', 'SubFrameworks']) {
      final dir = p.join(sdkPath, 'System', 'Library', sub);
      for (final entry in _list(files, dir)) {
        final name = p.basename(entry.path);
        if (!name.endsWith('.framework')) continue;
        final modulesDir = p.join(entry.path, 'Modules');
        if (!files.directory(modulesDir).existsSync()) continue;
        final module = p.basenameWithoutExtension(name);
        found.add(module);
        final owner = _publicModuleName(
          files,
          p.join(modulesDir, '$module.swiftmodule'),
        );
        if (owner != null && owner != module) details[module] = owner;
      }
    }

    // Swift-native modules: Swift, Darwin, Dispatch, os, Observation, ...
    found.addAll(
      _swiftModuleNames(files, p.join(sdkPath, 'usr', 'lib', 'swift')),
    );
    // Overlays shipped by the toolchain (Cxx, CxxStdlib).
    found.addAll(
      _swiftModuleNames(files, p.join(resourceDir, platformSdkName)),
    );

    // Clang modules declared by module maps (CommonCrypto, simd, ...).
    final include = p.join(sdkPath, 'usr', 'include');
    final maps = <String>[p.join(include, 'module.modulemap')];
    for (final entry in _list(files, include)) {
      if (entry is File && entry.path.endsWith('.modulemap')) {
        maps.add(entry.path);
      } else if (entry is Directory) {
        maps.add(p.join(entry.path, 'module.modulemap'));
      }
    }
    maps.add(p.join(resourceDir, 'clang', 'include', 'module.modulemap'));
    for (final map in maps) {
      final file = files.file(map);
      if (!file.existsSync()) continue;
      try {
        found.addAll(parseTopLevelModules(file.readAsStringSync()));
      } on FileSystemException {
        continue;
      }
    }
    return SwiftModuleIndex._(found, details);
  }

  /// Every module name resolvable.
  final Set<String> modules;

  /// Modules that exist in the SDK but that swiftc refuses to import because
  /// their interface declares `-public-module-name Other` (e.g. `SwiftUICore`
  /// for `SwiftUI`, `RealityFoundation` for `RealityKit`), mapped to `Other`.
  /// They are not in [modules], and [missing] reports them.
  final Map<String, String> implementationDetailOf;

  bool contains(String module) => modules.contains(module);

  /// The members of [required] that are not resolvable, sorted.
  List<String> missing(Iterable<String> required) =>
      required.toSet().where((m) => !modules.contains(m)).toList()..sort();

  /// Names of top-level `module` declarations in module map [source].
  ///
  /// Submodules (nested in braces, e.g. `module * { export * }`) are not
  /// importable as top-level names and must not leak, so brace depth is
  /// tracked. Comments and string literals are ignored.
  @visibleForTesting
  static Set<String> parseTopLevelModules(String source) {
    final names = <String>{};
    final text = _stripCommentsAndStrings(source);
    final decl = RegExp(
      r'^\s*(?:explicit\s+)?(?:framework\s+)?(?:extern\s+)?module\s+([A-Za-z_][A-Za-z0-9_.]*)',
    );
    var depth = 0;
    for (final line in text.split('\n')) {
      if (depth == 0) {
        final m = decl.firstMatch(line);
        if (m != null) names.add(m.group(1)!);
      }
      for (final c in line.codeUnits) {
        if (c == 0x7B) depth++;
        if (c == 0x7D && depth > 0) depth--;
      }
    }
    return names;
  }

  static String _stripCommentsAndStrings(String s) => s
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .replaceAll(RegExp(r'//[^\n]*'), '')
      .replaceAll(RegExp(r'"[^"\n]*"'), '""');

  /// The `-public-module-name` declared in the header of the first
  /// `.swiftinterface` under [swiftmodule], or null. Only the first few KB are
  /// read: the flags live on the third line of the interface.
  static String? _publicModuleName(
    HostFileSystemInterface files,
    String swiftmodule,
  ) {
    final interface = _list(
      files,
      swiftmodule,
    ).whereType<File>().where((f) => f.path.endsWith('.swiftinterface'));
    if (interface.isEmpty) return null;
    try {
      final raf = files.file(interface.first.path).openSync();
      try {
        final head = String.fromCharCodes(raf.readSync(8192));
        return publicModuleNameFromInterfaceHeader(head);
      } finally {
        raf.closeSync();
      }
    } on FileSystemException {
      return null;
    }
  }

  /// Extracts `X` from `-public-module-name X` in the `// swift-module-flags`
  /// comment lines of an interface [header].
  @visibleForTesting
  static String? publicModuleNameFromInterfaceHeader(String header) {
    for (final line in header.split('\n')) {
      if (!line.startsWith('// swift-module-flags')) continue;
      final m = RegExp(
        r'(?:^|\s)-public-module-name[\s=]+([A-Za-z_][A-Za-z0-9_]*)',
      ).firstMatch(line);
      if (m != null) return m.group(1);
    }
    return null;
  }

  static Iterable<FileSystemEntity> _list(
    HostFileSystemInterface files,
    String path,
  ) {
    final dir = files.directory(path);
    if (!dir.existsSync()) return const [];
    try {
      return dir.listSync(followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
    } on FileSystemException {
      return const [];
    }
  }

  static Iterable<String> _swiftModuleNames(
    HostFileSystemInterface files,
    String dir,
  ) sync* {
    for (final entry in _list(files, dir)) {
      final name = p.basename(entry.path);
      for (final ext in const ['.swiftmodule', '.swiftinterface']) {
        if (name.endsWith(ext)) {
          yield name.substring(0, name.length - ext.length);
        }
      }
    }
  }
}
