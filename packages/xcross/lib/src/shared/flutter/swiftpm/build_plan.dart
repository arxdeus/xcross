import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/ios_linker_compatibility.dart';
import 'package:xcross/src/flutter/build/preview_macro_stub_source.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/preview_macro_compiler.dart';
import 'package:xcross/src/shared/flutter/swiftpm/response_arguments.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmBuildPlan<T extends PlatformHostInterface> {
  SwiftPmBuildPlan({required this.filesystem,required this.hostPolicy,required this.runner,required this.previewCompiler});
  final SwiftPmFilesystem<T> filesystem;
  final SwiftPmHostPolicy hostPolicy;
  final ProcessRunner<T> runner;
  final SwiftPmPreviewMacroCompiler<T> previewCompiler;


  /// Disables Clang's implicit-module lock files, whose POSIX lock
  /// protocol deadlocks competing frontends on Windows.
  ///
  /// Applied to the C/Objective-C targets and to Swift's own frontend,
  /// which builds implicit Clang modules through the same cache.
  static const List<String> noImplicitModuleLockArguments = [
    '-Xcc',
    '-Xclang',
    '-Xcc',
    '-fno-implicit-modules-use-lock',
    '-Xswiftc',
    '-Xcc',
    '-Xswiftc',
    '-Xclang',
    '-Xswiftc',
    '-Xcc',
    '-Xswiftc',
    '-fno-implicit-modules-use-lock',
  ];

  /// Compiles and caches the Swift compiler plugin stub that answers
  /// `#Preview` macro-expansion requests with empty source, so builds
  /// succeed without Apple's `PreviewsMacros` plugin (an Xcode-only,
  /// closed-source binary with no host build of its own).
  ///
  /// `#Preview` is a freestanding declaration macro (SE-0394's SwiftUI
  /// sibling proposal), so expanding it to nothing is a legal expansion
  /// wherever it appears: previews are development-only UI and
  /// contribute nothing to the app being built. The stub speaks
  /// swift-syntax's own `StandardIOMessageConnection` wire protocol
  /// directly (an 8-byte little-endian length prefix, then UTF-8 JSON;
  /// see swift-syntax/Sources/SwiftCompilerPluginMessageHandling), so it
  /// has no swift-syntax dependency of its own, only C standard I/O.
  /// This is a real implementation of `swift build`'s public
  /// `-load-plugin-executable` extension point, not a source patch: no
  /// plugin source is read or modified.
  ///
  /// Its C source lives at `assets/preview_macro_stub.c` and is embedded
  /// as [previewMacroStubSource] — see that constant's doc comment.
  Future<String> writePreviewMacroStub({required String outputDir,required String cCompilerPath,List<String> cCompilerArguments=const []}) => previewCompiler.write(outputDir:outputDir,cCompilerPath:cCompilerPath,cCompilerArguments:cCompilerArguments);

  Future<String> writeObjectiveCCompatibilityHeader(String outputDir) async {
    final path = p.join(outputDir, '.xcross', 'objective-c-compatibility.h');
    await Directory(p.dirname(path)).create(recursive: true);
    await filesystem.writeStable(
      path,
      '#ifdef __OBJC__\n#import <Foundation/Foundation.h>\n#endif\n',
    );
    return path;
  }

  /// The directory SwiftPM writes build artifacts (`description.json`, the
  /// per-target `.build` folders) into, inside [scratchPath].
  ///
  /// Swift 6.4's swiftbuild engine drops the per-triple level and writes
  /// to `<scratch>/out/debug` instead of `<scratch>/<triple>/debug`. This
  /// build pins the native engine, which keeps the per-triple layout, so
  /// that is preferred: a stale `out/debug` left behind by a default-engine
  /// run must not win. When neither exists yet the per-triple path is
  /// returned so the missing-description diagnostic names a real location.
  static String resolveTargetBuildDir(
    String scratchPath, {
    String triple = 'arm64-apple-ios',
    String configuration = 'debug',
  }) {
    final candidates = [
      p.join(scratchPath, triple, configuration),
      p.join(scratchPath, 'out', configuration),
    ];
    for (final candidate in candidates) {
      if (File(p.join(candidate, 'description.json')).existsSync()) {
        return candidate;
      }
    }
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) return candidate;
    }
    return p.join(scratchPath, triple, configuration);
  }

  static List<String> plannedSwiftInteropSearchPaths(String targetBuildDir) {
    final description = File(p.join(targetBuildDir, 'description.json'));
    try {
      final decoded = jsonDecode(description.readAsStringSync());
      if (decoded is! Map<String, dynamic> ||
          decoded['swiftCommands'] is! Map<String, dynamic>) {
        throw const FormatException('Missing Swift command descriptions');
      }
      final includes = <String>{};
      for (final command
          in (decoded['swiftCommands'] as Map<String, dynamic>).values) {
        if (command is! Map<String, dynamic> ||
            command['otherArguments'] is! List ||
            !(command['otherArguments'] as List).every(
              (argument) => argument is String,
            )) {
          throw const FormatException('Invalid Swift command arguments');
        }
        final arguments = (command['otherArguments'] as List).cast<String>();
        for (var index = 0; index < arguments.length; index++) {
          if (arguments[index] != '-emit-objc-header-path') continue;
          if (++index >= arguments.length) {
            throw const FormatException('Missing generated header path');
          }
          final header = p.normalize(arguments[index]);
          if (!p.isAbsolute(header) ||
              !p.isWithin(p.normalize(p.absolute(targetBuildDir)), header) ||
              !header.endsWith('-Swift.h')) {
            throw const FormatException('Invalid generated header path');
          }
          includes.add(p.dirname(header));
        }
      }
      final sorted = includes.toList()..sort();
      return [
        for (final include in sorted) ...['-Xcc', '-I', '-Xcc', include],
      ];
    } on Object catch (error) {
      throw FlutterBuildError(
        'Cannot read planned Swift interop headers from '
        '${description.path}: $error',
      );
    }
  }

  /// Targets the build plan says will emit a `-Swift.h` that is not on disk.
  ///
  /// Unlike [missingSwiftInteropTargets], which can only see a module map
  /// SwiftPM has already written, this reads the plan, so it knows the full
  /// set before the first compile. That difference is what makes the prepass
  /// deterministic: on a cold build no module map exists yet, so scanning the
  /// build directory finds nothing to prebuild and the race is entered
  /// anyway.
  ///
  /// Names are returned in plan order so the prepass is reproducible.
  List<String> plannedSwiftInteropTargets(
    String targetBuildDir, {
    required Set<String> candidates,
  }) {
    // The plan is an optimisation for the prepass, not a requirement: without
    // it the existing after-the-fact recovery still runs. A build directory
    // with no readable plan therefore means "nothing to prebuild", not a
    // build failure.
    final List<String> planned;
    try {
      planned = SwiftPmBuildPlan.plannedSwiftInteropSearchPaths(targetBuildDir);
    } on Object {
      return const [];
    }
    // Only a target the aggregate actually reaches can be compiled by the
    // aggregate build, so only such a target can lose the header race the
    // prepass exists to prevent. The plan lists every target in the resolved
    // dependency graph, including the ones no product here depends on:
    // measured on examples/flutter_example that is 18 of 37, and each one
    // costs a whole `swift build` process (~4-13s on Windows) that can never
    // emit its header, because nothing schedules the target that would.
    // Prebuilding them was therefore pure latency, paid on every build,
    // forever: 13 unreachable targets re-prebuilt on each incremental run.
    final reachable = SwiftPmBuildPlan.plannedTargetClosure(
      targetBuildDir,
      pluginsProductName,
    );
    final targets = <String>{};
    for (final argument in planned) {
      final directory = p.basename(argument);
      if (directory != 'include') continue;
      final owner = p.basename(p.dirname(argument));
      if (!owner.endsWith('.build')) continue;
      final target = owner.substring(0, owner.length - '.build'.length);
      // A generated aggregate may reach an internal Swift target through a
      // product even though that target is not itself a public product.
      // Windows must include reachable internal Swift header targets,
      // including when older plans carry no dependency map. Preserve the
      // public-product candidate filter on POSIX hosts for every plan.
      if (!hostPolicy.includesInteropTarget(target, candidates)) {
        continue;
      }
      if (reachable != null && !reachable.contains(target)) continue;
      if (File(p.join(argument, '$target-Swift.h')).existsSync()) continue;
      targets.add(target);
    }
    final sorted = targets.toList()..sort();
    return sorted;
  }

  /// The aggregate target is the build that follows this prepass, never a
  /// prebuild target. Build reachable Swift dependencies before consumers
  /// even when alphabetical names would schedule them in reverse.
  static List<String> orderedWindowsSwiftInteropTargets(
    String targetBuildDir,
    List<String> planned,
  ) {
    final eligible = planned.toSet()..remove(pluginsProductName);
    final description = File(p.join(targetBuildDir, 'description.json'));
    Map<String, dynamic>? dependencies;
    try {
      final decoded = jsonDecode(description.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        dependencies = decoded['targetDependencyMap'] as Map<String, dynamic>?;
      }
    } on Object {
      // Preserve the prepass for older SwiftPM descriptions with no map.
    }
    final ordered = <String>[];
    final visited = <String>{};
    final visiting = <String>{};

    void visit(String target) {
      if (!eligible.contains(target) || visited.contains(target)) return;
      if (!visiting.add(target)) {
        throw FlutterBuildError(
          'SwiftPM interop target dependency cycle at $target',
        );
      }
      final children = dependencies?[target];
      if (children is List) {
        for (final dependency in children.whereType<String>()) {
          visit(dependency);
        }
      }
      visiting.remove(target);
      visited.add(target);
      ordered.add(target);
    }

    for (final target in planned) {
      visit(target);
    }
    return ordered;
  }

  /// [root] and every target reachable from it in the plan's dependency map.
  ///
  /// Returns null when the plan carries no usable dependency map, so callers
  /// can tell "nothing is reachable" apart from "reachability is unknown".
  static Set<String>? plannedTargetClosure(String targetBuildDir, String root) {
    final description = File(p.join(targetBuildDir, 'description.json'));
    final Map<String, List<String>> edges;
    try {
      final decoded = jsonDecode(description.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return null;
      final map = decoded['targetDependencyMap'];
      if (map is! Map<String, dynamic>) return null;
      edges = {
        for (final entry in map.entries)
          if (entry.value case final List<dynamic> dependencies)
            entry.key: [
              for (final dependency in dependencies)
                if (dependency is String) dependency,
            ],
      };
    } on Object {
      return null;
    }
    if (edges.isEmpty) return null;
    final seen = <String>{root};
    final stack = <String>[root];
    while (stack.isNotEmpty) {
      for (final next in edges[stack.removeLast()] ?? const <String>[]) {
        if (seen.add(next)) stack.add(next);
      }
    }
    return seen;
  }

  /// Whether the llbuild manifest already applies every interop search path.
  ///
  /// llbuild replays the command lines recorded in `debug.yaml` verbatim, so
  /// a manifest that already names each path produces exactly the build a
  /// re-plan would produce. The manifest is JSON-quoted, so the separators
  /// of a Windows path appear escaped.
  static bool manifestCarriesInteropSearchPaths(
    String scratchPath,
    List<String> interopArguments,
  ) {
    final manifest = File(p.join(scratchPath, 'debug.yaml'));
    final String text;
    try {
      text = manifest.readAsStringSync();
    } on Object {
      return false;
    }
    if (text.isEmpty) return false;
    // On Windows, long compiler command lines move into response files, so
    // a path may be recorded there instead of in the manifest itself.
    final responseArguments =
        SwiftPmResponseArguments.referencedResponseArguments(text, scratchPath);
    if (responseArguments == null) return false;
    bool recorded(String path) =>
        text.contains(jsonEncode(path)) ||
        responseArguments.contains(
          SwiftPmResponseArguments.quoteWindowsArgument(path),
        ) ||
        responseArguments.contains(
          SwiftPmResponseArguments.quoteGnuArgument(path),
        );
    var checked = 0;
    // [plannedSwiftInteropSearchPaths] emits each include as the quadruple
    // `-Xcc -I -Xcc <path>`, so the path follows the `-I` across the `-Xcc`
    // that forwards it to Clang.
    for (var index = 0; index + 2 < interopArguments.length; index++) {
      if (interopArguments[index] != '-I') continue;
      if (interopArguments[index + 1] != '-Xcc') continue;
      checked++;
      if (!recorded(interopArguments[index + 2])) return false;
    }
    return checked > 0;
  }

  /// Search-path arguments for the Objective-C interop modules SwiftPM
  /// generates under [targetBuildDir].
  ///
  /// A package whose Objective-C headers forward-declare types its Swift
  /// half implements leaves those declarations incomplete for anything that
  /// reads the headers alone, which drops every member mentioning them.
  /// Swift emits the completing declarations into `<Module>.build/include`,
  /// and SwiftPM puts that directory on the search path of the targets it
  /// knows consume the Swift module. A target reaching the same headers
  /// through a generated compatibility module is not one of them, so Clang
  /// never sees the completing declarations. Passing the directories to
  /// Clang covers those targets as well.
  ///
  /// SwiftPM writes each directory before compiling the targets that depend
  /// on it, so on a clean build this starts empty and fills in as the
  /// dependencies are built.
  static List<String> swiftInteropSearchPaths(String targetBuildDir) {
    final directory = Directory(targetBuildDir);
    if (!directory.existsSync()) return const [];
    final includes = <String>[];
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (!name.endsWith('.build')) continue;
      final include = p.join(entity.path, 'include');
      final module = name.substring(0, name.length - '.build'.length);
      if (File(p.join(include, '$module-Swift.h')).existsSync()) {
        includes.add(include);
      }
    }
    includes.sort();
    return [
      for (final include in includes) ...['-Xcc', '-I', '-Xcc', include],
    ];
  }

  /// Arguments shared by Linux and Windows SwiftPM builds. SDK-owned compiler
  /// flags stay in SDK metadata; only package-specific flags belong here.
  List<String> swiftBuildArguments({
    required String pluginsDir,
    required String scratchPath,
    required String swiftSdksPath,
    required String iosSdk,
    required String flutterFrameworkSlice,
    String swiftSdkTriple = 'arm64-apple-ios',
    String? objectiveCCompatibilityHeader,
    String? toolsetPath,
    String? linkerPath,
    List<String> interopSearchPaths = const [],
    String? previewMacroStubPath,
  }) => [
    ...hostPolicy.buildPrefix,
    '--package-path',
    pluginsDir,
    // Swift 6.4 made `swiftbuild` the default build system. It only knows
    // the Apple platforms a host Xcode registers, so on a cross host it
    // rejects this build outright with 'unable to find platform for
    // iphoneos', and it drops the per-triple level from the scratch layout
    // this code reads its build description from. The native engine is what
    // supports the cross build, so ask for it rather than inherit the default.
    '--build-system',
    'native',
    '--configuration',
    'debug',
    // A debug build with DWARF makes swift-driver plan a dSYM job for Darwin
    // targets, and that job needs a `dsymutil` no cross host is guaranteed to
    // have ("error: unableToFind(tool: \"dsymutil\")" on Linux). Nothing here
    // consumes a dSYM — only the dylibs are collected — and the Runner is
    // compiled without debug info too, so drop it instead of adding a tool
    // requirement.
    '-debug-info-format',
    'none',
    '--swift-sdks-path',
    swiftSdksPath,
    '--swift-sdk',
    swiftSdkTriple,
    if (toolsetPath != null) ...['--toolset', toolsetPath],
    '--scratch-path',
    scratchPath,
    ...hostPolicy.buildArguments,
    ...interopSearchPaths,
    // Apple's `PreviewsMacros` plugin ships only inside Xcode, so `#Preview`
    // needs the stub on every cross host, not just Windows.
    if (previewMacroStubPath != null) ...[
      '-Xswiftc',
      '-load-plugin-executable',
      '-Xswiftc',
      '$previewMacroStubPath#PreviewsMacros',
    ],
    // On macOS, SwiftPM's host toolchain can override the Swift SDK bundle's
    // sdkRootPath with the host MacOSX SDK. Pin the installed iPhoneOS SDK for
    // Swift imports and every C/Objective-C target so UIKit and Foundation are
    // resolved from the target platform on every host.
    '-Xswiftc',
    '-sdk',
    '-Xswiftc',
    iosSdk,
    '-Xcc',
    '-isysroot',
    '-Xcc',
    iosSdk,
    if (objectiveCCompatibilityHeader != null) ...[
      '-Xcc',
      '-include',
      '-Xcc',
      objectiveCCompatibilityHeader,
    ],
    '-Xswiftc',
    '-F',
    '-Xswiftc',
    flutterFrameworkSlice,
    '-Xcc',
    '-F',
    '-Xcc',
    flutterFrameworkSlice,
    // Preserve Swift #available runtime guards. Disabling availability checks
    // also removes these guards and can call newer weak-linked APIs on older
    // operating systems where those weak-linked APIs do not exist.
    // Swift uses clang as its link driver. Pin that driver too, otherwise a
    // macOS host reselects MacOSX.sdk while linking iOS plugin products.
    '-Xswiftc',
    '-Xclang-linker',
    '-Xswiftc',
    '-isysroot',
    '-Xswiftc',
    '-Xclang-linker',
    '-Xswiftc',
    iosSdk,
    ...objectiveCLinkerSwiftDriverArguments,
    ...hostPolicy.linkerArguments,
    // The link runs through the toolchain's own clang, which resolves
    // `-use-ld=lld` to the `ld64.lld` sitting next to itself — swiftly's, the
    // one that refuses iOS (see [resolveLd64Lld]). `--ld-path` overrides that
    // choice with the stock LLVM linker.
    if (linkerPath != null)
      ...hostPolicy.linkerPathArguments(linkerPath),
  ];
}
