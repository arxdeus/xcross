import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_plugins.dart';
import 'package:xcross/src/flutter/build/macho_dylib_rewriter.dart';
import 'package:xcross/src/flutter/build/preview_macro_stub_source.dart';
import 'package:xcross/src/flutter/constants.dart';
import 'package:xcross/src/flutter/errors.dart';

/// Name of the synthetic package/product/binary-target that wraps the real
/// `Flutter.xcframework` as a SwiftPM binary target (SwiftPM binary-target
/// paths must be relative to their own package, so the framework can't be
/// referenced directly from the aggregate plugins package). Mirrors
/// flutter_tools' own `kFlutterGeneratedFrameworkSwiftPackageTargetName`.
const String _flutterFrameworkPackageName = 'FlutterFramework';

/// Name of our aggregate package/product/target that pulls in every SPM
/// plugin's native code.
const String _pluginsProductName = 'FlutterPluginsGenerated';

/// Result of building the aggregate Flutter-plugins Swift package.
final class GeneratedPluginsBuildResult {
  /// Creates a result wrapping the built dylib paths.
  const GeneratedPluginsBuildResult({
    required this.libraryPath,
    required this.dylibPaths,
  });

  /// Absolute path to the built `libFlutterPluginsGenerated.dylib`.
  final String libraryPath;

  /// Absolute paths to every dynamic library produced by SwiftPM.
  final List<String> dylibPaths;
}

/// Synthesizes and builds a Swift Package Manager package that aggregates
/// every Flutter plugin's iOS SPM native code into one dynamic library,
/// cross-compiled on Linux or Windows via a Darwin-SDK-backed `swift build
/// --swift-sdk`.
///
/// Mirrors Flutter's own SPM plugin integration: a generated wrapper package
/// depending on every plugin package plus a `FlutterFramework` binary-target
/// wrapper around `Flutter.xcframework`. Two deliberate differences from
/// Flutter's tool: `.package(path:)` entries use absolute paths (there is no
/// committed Xcode project here to keep portable), and the aggregate is a
/// *dynamic* library, so its produced dylibs can be embedded under
/// `Frameworks` and Runner can link only the aggregate instead of hand-deriving
/// Swift-runtime autolink flags for a static library.
abstract final class GeneratedPluginsPackage {
  /// Builds the aggregate dylib for the subset of [plugins] that use Swift
  /// Package Manager. Returns null if there is nothing to build.
  ///
  /// [projectRoot]        — Flutter project root (logging context only).
  /// [flutterXcframework] — Path to the real `Flutter.xcframework` (from
  ///                         `IosEngineCache.flutterXcframework`).
  /// [outputDir]           — Stable directory to synthesize the wrapper
  ///                         packages and run `swift build` in. Not deleted
  ///                         between calls, so SwiftPM's `.build` cache
  ///                         persists; only the generated `.swift` files are
  ///                         overwritten each call.
  static Future<GeneratedPluginsBuildResult?> build({
    required String projectRoot,
    required List<IosPlugin> plugins,
    required String flutterXcframework,
    required String outputDir,
    required IosDeploymentTarget deploymentTarget,
  }) =>
      Log.logStep('Building Flutter plugins (Swift Package Manager)', () async {
        final spmPlugins = plugins
            .where((plugin) => plugin.usesSwiftPackageManager)
            .toList();
        if (spmPlugins.isEmpty) return null;

        Log.logTrace(
          'projectRoot=$projectRoot '
          'spmPlugins=${[for (final plugin in spmPlugins) plugin.name]}',
        );

        await writeGeneratedPackages(
          outputDir: outputDir,
          plugins: spmPlugins,
          flutterXcframework: flutterXcframework,
          deploymentTarget: deploymentTarget,
        );

        final pluginsDir = p.join(outputDir, 'Plugins');
        final scratchPath = p.join(pluginsDir, '.build');
        await _runSwiftBuild(
          outputDir: outputDir,
          pluginsDir: pluginsDir,
          scratchPath: scratchPath,
          flutterXcframework: flutterXcframework,
        );

        return discoverAndRewriteDylibs(
          p.join(scratchPath, 'arm64-apple-ios', 'debug'),
        );
      });

  /// Cross-compiles the synthesized packages in [pluginsDir] with
  /// `swift build --swift-sdk arm64-apple-ios`.
  static Future<void> _runSwiftBuild({
    required String outputDir,
    required String pluginsDir,
    required String scratchPath,
    required String flutterXcframework,
  }) async {
    final sdk = DarwinSdk.current();
    if (sdk == null) {
      throw FlutterBuildError(
        'Darwin Swift SDK not found. Run '
        '`xcross sdk install <Xcode.xip>` first.',
      );
    }
    final swift = await ProcessRunner.locateTool('swift');
    // Real `Flutter.framework` (not our FlutterFramework binary-target
    // wrapper). Our own aggregate target resolves `import Flutter` via
    // that wrapper's declared package dependency, but individual
    // third-party plugin targets often don't declare any such dependency
    // in their own Package.swift at all — they rely on Xcode's implicit,
    // project-wide framework search paths to make `import Flutter` resolve
    // (verified against a real published plugin: its manifest lists zero
    // dependencies, yet its Swift source does `import Flutter`). A plain
    // `swift build` has no such implicit project-wide behaviour, so we
    // reproduce it ourselves with build-wide framework search flags. Swift
    // targets need `-Xswiftc -F`; C and Objective-C targets need the matching
    // `-Xcc -F` pair so imports such as `<Flutter/Flutter.h>` resolve too.
    final flutterFrameworkSlice = p.join(flutterXcframework, 'ios-arm64');
    final linker = await DarwinSdk.resolveLd64Lld(sdk);
    final darwinClang = Platform.isWindows
        ? await DarwinSdk.resolveDarwinClang(sdk)
        : null;
    final toolsetPath = await writeToolset(
      outputDir: outputDir,
      linkerPath: linker,
      cCompilerPath: darwinClang,
      cxxCompilerPath: Platform.isWindows
          ? await DarwinSdk.resolveDarwinClang(sdk, name: 'clang++')
          : null,
    );
    // Apple's real `#Preview` macro plugin ships only inside Xcode, so no
    // cross host has it. The compiled stub answers the macro through
    // Swift's own `-load-plugin-executable` extension point instead — its
    // host compiler is whichever one built [darwinClang], available on
    // every host that can build this project at all.
    final previewMacroStub = await writePreviewMacroStub(
      outputDir: outputDir,
      cCompilerPath: darwinClang ?? await ProcessRunner.locateTool('cc'),
    );
    final swiftSdksPath = p.dirname(sdk.swiftSdkPath);
    final environment = swiftProcessEnvironment(windows: Platform.isWindows);
    if (Platform.isWindows) {
      await ProcessRunner.runChecked(
        swift,
        swiftResolveArguments(
          pluginsDir: pluginsDir,
          scratchPath: scratchPath,
          swiftSdksPath: swiftSdksPath,
          toolsetPath: toolsetPath,
        ),
        environment: environment,
        inheritStdio: Log.isVerbose,
        label: 'swift package resolve',
      );
      await materializeCheckoutSymlinks(scratchPath);
      for (final root in [
        p.join(outputDir, 'Packages'),
        p.join(outputDir, 'Vendor'),
        p.join(scratchPath, 'checkouts'),
      ]) {
        await normalizeHostSwiftTree(root);
      }
    }
    final targetBuildDir = p.join(scratchPath, 'arm64-apple-ios', 'debug');
    // A target that reaches a package's Objective-C headers through a
    // generated compatibility module needs the interop headers Swift emits
    // for that package, and SwiftPM does not put them on its search path.
    // Those headers only exist once their own target has been built, so on
    // Windows the build is retried with whatever is present: the first run
    // emits them and fails at the target that needs them, the retry
    // compiles that target. Builds are incremental, so the retry only
    // builds what the first run could not.
    Future<void> build() => ProcessRunner.runChecked(
      swift,
      swiftBuildArguments(
        pluginsDir: pluginsDir,
        scratchPath: scratchPath,
        swiftSdksPath: swiftSdksPath,
        iosSdk: sdk.iPhoneOSSdk(),
        flutterFrameworkSlice: flutterFrameworkSlice,
        toolsetPath: toolsetPath,
        // Windows gets the same override from the toolset's `linker`.
        linkerPath: Platform.isWindows ? null : linker,
        windows: Platform.isWindows,
        interopSearchPaths: Platform.isWindows
            ? swiftInteropSearchPaths(targetBuildDir)
            : const [],
        previewMacroStubPath: previewMacroStub,
      ),
      environment: environment,
      inheritStdio: Log.isVerbose,
      label: 'swift build',
    );

    if (!Platform.isWindows) {
      await build();
      return;
    }
    final before = swiftInteropSearchPaths(targetBuildDir);
    try {
      await build();
    } on Object {
      // Only retry when the failed run emitted interop headers the next one
      // can use, so a genuine compile error still fails once.
      if (swiftInteropSearchPaths(targetBuildDir).length == before.length) {
        rethrow;
      }
      await build();
    }
  }

  /// Process-local settings for Windows SwiftPM dependency checkout and
  /// sentry-cocoa's source-build manifest lane.
  @visibleForTesting
  static Map<String, String>? swiftProcessEnvironment({bool? windows}) {
    if (!(windows ?? Platform.isWindows)) return null;
    return const {
      'GIT_CONFIG_COUNT': '1',
      'GIT_CONFIG_KEY_0': 'core.symlinks',
      'GIT_CONFIG_VALUE_0': 'false',
      'EXPERIMENTAL_SPM_BUILDS': '1',
    };
  }

  /// Resolves Windows dependencies before tracked symlink placeholders are
  /// materialized and automatic resolution is disabled for the build.
  @visibleForTesting
  static List<String> swiftResolveArguments({
    required String pluginsDir,
    required String scratchPath,
    required String swiftSdksPath,
    required String toolsetPath,
  }) => [
    'package',
    '--package-path',
    pluginsDir,
    '--scratch-path',
    scratchPath,
    '--swift-sdks-path',
    swiftSdksPath,
    '--swift-sdk',
    'arm64-apple-ios',
    '--toolset',
    toolsetPath,
    'resolve',
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
  @visibleForTesting
  static Future<String> writePreviewMacroStub({
    required String outputDir,
    required String cCompilerPath,
    bool? windows,
  }) async {
    final onWindows = windows ?? Platform.isWindows;
    final stubDir = p.join(outputDir, '.xcross', 'preview-macro-stub');
    await Directory(stubDir).create(recursive: true);
    final sourcePath = p.join(stubDir, 'stub.c');
    await _writeStable(sourcePath, previewMacroStubSource);
    final exePath = p.join(
      stubDir,
      ProcessRunner.hostExecutableName('stub', windows: onWindows),
    );
    // The stub only depends on its own source, so a matching binary from
    // a previous build needs no recompilation.
    if (File(exePath).existsSync()) return exePath;
    await ProcessRunner.runChecked(cCompilerPath, [
      '-O2',
      '-o',
      exePath,
      sourcePath,
    ], label: 'compile preview macro stub');
    return exePath;
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
  @visibleForTesting
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

  /// Disables Clang's implicit-module lock files, whose POSIX lock
  /// protocol deadlocks competing frontends on Windows.
  ///
  /// Applied to the C/Objective-C targets and to Swift's own frontend,
  /// which builds implicit Clang modules through the same cache.
  @visibleForTesting
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

  /// Arguments shared by Linux and Windows SwiftPM builds. SDK-owned compiler
  /// flags stay in SDK metadata; only package-specific flags belong here.
  @visibleForTesting
  static List<String> swiftBuildArguments({
    required String pluginsDir,
    required String scratchPath,
    required String swiftSdksPath,
    required String iosSdk,
    required String flutterFrameworkSlice,
    String? toolsetPath,
    String? linkerPath,
    bool? windows,
    List<String> interopSearchPaths = const [],
    String? previewMacroStubPath,
  }) => [
    'build',
    '--package-path',
    pluginsDir,
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
    'arm64-apple-ios',
    if (toolsetPath != null) ...['--toolset', toolsetPath],
    '--scratch-path',
    scratchPath,
    if (windows ?? Platform.isWindows) ...[
      '--disable-automatic-resolution',
      // Windows Swift's interface verifier does not inherit SwiftPM's search
      // path for generated sibling Clang modules during Darwin cross builds.
      // The binary module is still emitted and used by this debug build.
      '-Xswiftc',
      '-no-verify-emitted-module-interface',
      // Clang guards implicit module builds with filesystem lock files so
      // competing invocations reuse one another's work instead of building
      // the same module twice. That protocol assumes POSIX lock semantics
      // and deadlocks on Windows: the frontend holding a module's lock
      // stops progressing and every other frontend waits on it forever, so
      // the build hangs with no diagnostic and no CPU use. Each build owns
      // its module cache, so dropping the lock only risks building a module
      // twice in parallel, which is far cheaper than hanging. Swift builds
      // implicit Clang modules through its own frontend, so it needs the
      // flag as well as the C/Objective-C targets.
      ...noImplicitModuleLockArguments,
      ...interopSearchPaths,
      if (previewMacroStubPath != null) ...[
        '-Xswiftc',
        '-load-plugin-executable',
        '-Xswiftc',
        '$previewMacroStubPath#PreviewsMacros',
      ],
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
    '-Xswiftc',
    '-F',
    '-Xswiftc',
    flutterFrameworkSlice,
    '-Xcc',
    '-F',
    '-Xcc',
    flutterFrameworkSlice,
    '-Xswiftc',
    '-Xfrontend',
    '-Xswiftc',
    '-disable-availability-checking',
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
    // The link runs through the toolchain's own clang, which resolves
    // `-use-ld=lld` to the `ld64.lld` sitting next to itself — swiftly's, the
    // one that refuses iOS (see [resolveLd64Lld]). `--ld-path` overrides that
    // choice with the stock LLVM linker.
    if (linkerPath != null) ...[
      '-Xswiftc',
      '-Xclang-linker',
      '-Xswiftc',
      '--ld-path=$linkerPath',
    ],
  ];

  /// Finds and fixes every dylib emitted into SwiftPM's target debug output.
  @visibleForTesting
  static Future<GeneratedPluginsBuildResult> discoverAndRewriteDylibs(
    String targetDebugDir,
  ) async {
    final dylibPaths = <String>[];
    await for (final entity in Directory(targetDebugDir).list()) {
      if (entity is File && p.extension(entity.path) == '.dylib') {
        dylibPaths.add(p.absolute(entity.path));
      }
    }
    dylibPaths.sort();

    const aggregateName = 'lib$_pluginsProductName.dylib';
    final aggregatePath = dylibPaths
        .where((path) => p.basename(path) == aggregateName)
        .firstOrNull;
    if (aggregatePath == null) {
      throw FlutterBuildError(
        'GeneratedPluginsPackage: swift build did not produce the plugins '
        'library in $targetDebugDir',
      );
    }

    final dylibNames = dylibPaths.map(p.basename).toSet();
    for (final path in dylibPaths) {
      await MachODylibRewriter.rewriteFile(
        path,
        producedDylibNames: dylibNames,
      );
    }
    return GeneratedPluginsBuildResult(
      libraryPath: aggregatePath,
      dylibPaths: List.unmodifiable(dylibPaths),
    );
  }

  /// LLVM's drop-in replacement for Apple's `libtool`.
  static const _libtool = 'llvm-libtool-darwin';

  /// Every archiver SwiftPM may be pointed at, best first.
  static const _librarians = [_libtool, 'llvm-ar'];

  /// Writes SwiftPM's external toolset and returns its path.
  ///
  /// Every host needs the `librarian` entry: SwiftPM validates the toolchain
  /// against the *target* triple before building, and for an Apple triple that
  /// means Apple's `libtool` ("toolchain is invalid: could not find CLI tool
  /// `libtool`"), which no cross host has. Windows overrides the compilers and
  /// the linker on top; Linux passes its linker as a `swift build` flag
  /// instead.
  @visibleForTesting
  static Future<String> writeToolset({
    required String outputDir,
    required String linkerPath,
    String? cCompilerPath,
    String? cxxCompilerPath,
    bool? windows,
    Future<String?> Function(String name)? locateTool,
  }) async {
    final onWindows = windows ?? Platform.isWindows;
    final output = Directory(outputDir);
    await output.create(recursive: true);
    // LLVM often never registers itself on PATH, so reach into its install
    // directories too (see [DarwinSdk.llvmToolDirs]).
    final locate = locateTool ?? DarwinSdk.locateLlvmTool;
    final toolset = <String, Object>{
      'schemaVersion': '1.0',
      'rootPath': _jsonPath(output.resolveSymbolicLinksSync()),
    };

    Future<String?> resolve(String name) async {
      final path = await locate(
        ProcessRunner.hostExecutableName(name, windows: onWindows),
      );
      return path == null
          ? null
          : _jsonPath(File(path).resolveSymbolicLinksSync());
    }

    final librarian = await _resolveLibrarian(onWindows, resolve);
    if (librarian == null) {
      throw FlutterBuildError(
        'No Darwin-capable archiver found (${_librarians.join(' or ')}). '
        'Install LLVM and retry.',
      );
    }
    toolset['librarian'] = {'path': librarian};

    if (onWindows) {
      // Vetted by DarwinSdk.resolveDarwinClang where the caller could do it;
      // a plain lookup is the fallback for tests and older call sites.
      final tools = <String, (String, String?)>{
        'cCompiler': ('clang', cCompilerPath),
        'cxxCompiler': ('clang++', cxxCompilerPath),
      };
      for (final tool in tools.entries) {
        final vetted = tool.value.$2;
        final path = vetted == null
            ? await resolve(tool.value.$1)
            : _jsonPath(File(vetted).resolveSymbolicLinksSync());
        if (path == null) {
          throw FlutterBuildError('Could not find ${tool.value.$1}.');
        }
        toolset[tool.key] = {'path': path};
      }
      // The Swift toolchain's own ld64.lld refuses iOS, so take the linker
      // already vetted by DarwinSdk.resolveLd64Lld instead of PATH order.
      toolset['linker'] = {
        'path': _jsonPath(File(linkerPath).resolveSymbolicLinksSync()),
      };
    }

    final toolsetPath = p.join(outputDir, 'xcross-toolset.json');
    await _writeStable(
      toolsetPath,
      '${const JsonEncoder.withIndent('  ').convert(toolset)}\n',
    );
    return toolsetPath;
  }

  /// Picks the archiver for an Apple target: `llvm-libtool-darwin` when it is
  /// on PATH, else the copy sitting next to `llvm-ar` inside LLVM's own bin
  /// directory (Debian and Ubuntu only symlink a subset of LLVM into
  /// `/usr/bin`), else `llvm-ar` itself.
  static Future<String?> _resolveLibrarian(
    bool windows,
    Future<String?> Function(String name) resolve,
  ) async {
    final libtool = await resolve(_libtool);
    if (libtool != null) return libtool;
    final archiver = await resolve('llvm-ar');
    if (archiver == null) return null;
    final sibling = p.join(
      p.dirname(archiver),
      ProcessRunner.hostExecutableName(_libtool, windows: windows),
    );
    return File(sibling).existsSync() ? _jsonPath(sibling) : archiver;
  }

  /// Writes the `FlutterFramework` and `Plugins` wrapper packages (manifests,
  /// registrant source, and the `Flutter.xcframework` link/copy) under
  /// [outputDir], without invoking `swift build`. Split out from [build] so
  /// the file-synthesis logic is testable without a Swift toolchain.
  ///
  /// When [vendorRemotePackages] is true (default on Windows), every
  /// `.package(url:)` dependency in a plugin manifest is cloned under
  /// `outputDir/Vendor/`, host-normalized, and rewritten to a `.package(path:)`
  /// so SwiftPM never host-evaluates broken remote manifests (e.g. sentry-cocoa
  /// `getenv` via removed `MSVCRT`).
  @visibleForTesting
  static Future<void> writeGeneratedPackages({
    required String outputDir,
    required List<IosPlugin> plugins,
    required String flutterXcframework,
    required IosDeploymentTarget deploymentTarget,
    bool? copyFlutterXcframework,
    bool? vendorRemotePackages,
  }) async {
    final packagesDir = p.join(outputDir, 'Packages');
    final frameworkDir = p.join(packagesDir, _flutterFrameworkPackageName);
    final pluginsDir = p.join(outputDir, 'Plugins');
    final vendorDir = p.join(outputDir, 'Vendor');
    final shouldVendor = vendorRemotePackages ?? Platform.isWindows;

    await Directory(packagesDir).create(recursive: true);
    await _writeFlutterFrameworkPackage(
      frameworkDir: frameworkDir,
      flutterXcframework: flutterXcframework,
      copyFlutterXcframework: copyFlutterXcframework ?? Platform.isWindows,
    );

    final pluginPackageDirs = <String, String>{};
    for (final plugin in plugins) {
      final packageAlias = p.join(packagesDir, plugin.name);
      pluginPackageDirs[plugin.name] = await _stagePluginPackage(
        alias: packageAlias,
        target: plugin.swiftPackageDir,
        vendorDir: shouldVendor ? vendorDir : null,
      );
    }
    await _writePluginsPackage(
      pluginsDir: pluginsDir,
      frameworkDir: frameworkDir,
      plugins: plugins,
      pluginPackageDirs: pluginPackageDirs,
      deploymentTarget: deploymentTarget,
    );
  }

  /// Stages [target] at [alias], using a shallow overlay when the Swift
  /// manifest needs host fixes (linker flags, Windows CRT imports) or when
  /// remote URL dependencies are vendored to path deps.
  static Future<String> _stagePluginPackage({
    required String alias,
    required String target,
    String? vendorDir,
  }) async {
    var stagedPackage = alias;
    if (vendorDir != null) {
      await _deleteUnless(alias, FileSystemEntityType.directory);
      final packageRoot = p.dirname(p.dirname(target));
      await _stageAncestorOverlay(
        sourceRoot: packageRoot,
        destinationRoot: alias,
        packageName: p.basename(target),
      );
      await _createDirectoryAlias(
        p.join(alias, 'ios', _flutterFrameworkPackageName),
        p.join(p.dirname(alias), _flutterFrameworkPackageName),
      );
      stagedPackage = p.join(alias, 'ios', p.basename(target));
    }

    final manifest = await File(p.join(target, 'Package.swift')).readAsString();
    var normalizedManifest = normalizeHostManifest(manifest);
    final fallbackSwiftModules = <String, List<String>>{};
    if (vendorDir != null) {
      normalizedManifest = await vendorUrlPackagesAsPathDeps(
        normalizedManifest,
        vendorDir: vendorDir,
        fallbackSwiftModules: fallbackSwiftModules,
      );
    }

    if (vendorDir != null) {
      // Normalizing during the mirror keeps re-runs byte-stable: copying
      // first and normalizing after would rewrite (and re-timestamp) every
      // normalized source on every build.
      await _mirrorPluginPackage(
        target,
        stagedPackage,
        normalizedManifest,
        transform: _hostSwiftTransform(fallbackSwiftModules),
      );
    } else if (normalizedManifest == manifest) {
      await _createDirectoryAlias(stagedPackage, target);
      await normalizeHostSwiftTree(
        stagedPackage,
        fallbackSwiftModules: fallbackSwiftModules,
      );
    } else {
      await _overlayPluginManifest(target, stagedPackage, normalizedManifest);
      await normalizeHostSwiftTree(
        stagedPackage,
        fallbackSwiftModules: fallbackSwiftModules,
      );
    }
    return stagedPackage;
  }

  /// Mirrors [target] at [staged] with [manifest] as its `Package.swift`.
  ///
  /// Only differing files are rewritten, so a rebuild presents SwiftPM with
  /// the timestamps it already compiled and its incremental state stays
  /// warm.
  static Future<void> _mirrorPluginPackage(
    String target,
    String staged,
    String manifest, {
    _SourceTransform? transform,
  }) async {
    await _deleteUnless(staged, FileSystemEntityType.directory);
    await _syncDirectory(
      target,
      staged,
      preserve: const {'Package.swift'},
      transform: transform,
    );
    await _writeStable(p.join(staged, 'Package.swift'), manifest);
  }

  /// The host-compatibility source rewrite as a sync transform, electing
  /// Swift sources but never package manifests or binary files.
  static _SourceTransform _hostSwiftTransform(
    Map<String, List<String>> fallbackSwiftModules,
  ) => (path) {
    final name = p.basename(path);
    final isManifest =
        name == 'Package.swift' ||
        (name.startsWith('Package@') && name.endsWith('.swift'));
    if (p.extension(name) != '.swift' || isManifest) return null;
    return (content) => normalizeHostSwiftSource(
      content,
      fallbackSwiftModules: fallbackSwiftModules,
    );
  };

  /// Stages [target] at [staged] as per-entry aliases beneath a rewritten
  /// `Package.swift`, for hosts where symbolic links are first-class.
  static Future<void> _overlayPluginManifest(
    String target,
    String staged,
    String manifest,
  ) async {
    await _deleteEntity(staged);
    await Directory(staged).create(recursive: true);
    await _writeStable(p.join(staged, 'Package.swift'), manifest);
    await for (final entity in Directory(target).list(followLinks: false)) {
      if (p.basename(entity.path) == 'Package.swift') continue;
      await _stageEntity(
        entity,
        p.join(staged, p.basename(entity.path)),
        copyDirectories: false,
      );
    }
  }

  /// Package-root entries a plugin's iOS SwiftPM build can never reach:
  /// Dart code, other platforms, development trees, and pub metadata.
  ///
  /// This is a sparse checkout by exclusion rather than inclusion because
  /// the reachable remainder has no fixed shape: published plugins refer
  /// to arbitrary sibling directories from their iOS package (`../../src`
  /// sources, `../../include` header search paths, shared `darwin/`
  /// trees), so only the provably unreachable entries are skipped.
  static const _iosUnreachableEntries = {
    // development trees
    '.dart_tool',
    '.git',
    '.github',
    'build',
    'example',
    'test',
    'tests',
    // dart code and pub metadata
    'lib',
    'pubspec.yaml',
    'pubspec.lock',
    'analysis_options.yaml',
    'readme.md',
    'changelog.md',
    // other platforms ('darwin' stays: it is shared with iOS)
    'android',
    'macos',
    'windows',
    'linux',
    'web',
    // pigeon input definitions: consumed by the pigeon generator at
    // development time, never referenced by the generated iOS build
    'pigeons',
  };

  static Future<void> _stageAncestorOverlay({
    required String sourceRoot,
    required String destinationRoot,
    required String packageName,
  }) async {
    await Directory(p.join(destinationRoot, 'ios')).create(recursive: true);
    final staged = <String>{'ios'};
    await for (final entity in Directory(sourceRoot).list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name == 'ios' ||
          _iosUnreachableEntries.contains(name.toLowerCase())) {
        continue;
      }
      staged.add(name);
      await _stageEntity(
        entity,
        p.join(destinationRoot, name),
        copyDirectories: true,
        excludedSourcePath: destinationRoot,
      );
    }
    await _pruneUnexpected(destinationRoot, staged);

    final stagedIos = <String>{packageName, _flutterFrameworkPackageName};
    await for (final entity in Directory(
      p.join(sourceRoot, 'ios'),
    ).list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name == packageName || name == _flutterFrameworkPackageName) continue;
      stagedIos.add(name);
      await _stageEntity(
        entity,
        p.join(destinationRoot, 'ios', name),
        copyDirectories: true,
        excludedSourcePath: destinationRoot,
      );
    }
    await _pruneUnexpected(p.join(destinationRoot, 'ios'), stagedIos);
  }

  /// Deletes entries of [directory] not named in [expected], so previously
  /// staged files that no longer qualify do not linger in the build tree.
  static Future<void> _pruneUnexpected(
    String directory,
    Set<String> expected,
  ) async {
    await for (final entity in Directory(directory).list(followLinks: false)) {
      if (!expected.contains(p.basename(entity.path))) {
        await _deleteEntity(entity.path);
      }
    }
  }

  static Future<void> _stageEntity(
    FileSystemEntity entity,
    String destination, {
    required bool copyDirectories,
    String? excludedSourcePath,
  }) async {
    final resolved = entity is Link
        ? entity.resolveSymbolicLinksSync()
        : entity.path;
    if (!Directory(resolved).existsSync()) {
      await _syncFile(File(resolved), destination);
    } else if (copyDirectories) {
      await _syncDirectory(
        resolved,
        destination,
        excludedSourcePath: excludedSourcePath,
      );
    } else {
      await _createDirectoryAlias(destination, resolved);
    }
  }

  /// Writes `FlutterFramework/Package.swift` and links or copies the real
  /// [flutterXcframework]. Windows copies because creating symlinks commonly
  /// requires Developer Mode or elevation.
  static Future<void> _writeFlutterFrameworkPackage({
    required String frameworkDir,
    required String flutterXcframework,
    required bool copyFlutterXcframework,
  }) async {
    await Directory(frameworkDir).create(recursive: true);
    await _writeStable(
      p.join(frameworkDir, 'Package.swift'),
      flutterFrameworkManifest(),
    );

    final frameworkPath = p.join(frameworkDir, 'Flutter.xcframework');
    if (copyFlutterXcframework) {
      await _deleteUnless(frameworkPath, FileSystemEntityType.directory);
      await _syncDirectory(flutterXcframework, frameworkPath);
    } else {
      await _deleteEntity(frameworkPath);
      await Link(frameworkPath).create(flutterXcframework);
    }
  }

  /// Writes `Plugins/Package.swift` and the generated registrant source.
  static Future<void> _writePluginsPackage({
    required String pluginsDir,
    required String frameworkDir,
    required List<IosPlugin> plugins,
    required Map<String, String> pluginPackageDirs,
    required IosDeploymentTarget deploymentTarget,
  }) async {
    final sourcesDir = p.join(pluginsDir, 'Sources', _pluginsProductName);
    await Directory(sourcesDir).create(recursive: true);

    await _writeStable(
      p.join(pluginsDir, 'Package.swift'),
      pluginsManifest(
        plugins,
        frameworkDir,
        pluginPackageDirs: pluginPackageDirs,
        deploymentTarget: deploymentTarget,
      ),
    );

    await _writeStable(
      p.join(sourcesDir, 'GeneratedPluginRegistrant.swift'),
      registrantSource(plugins),
    );
  }

  /// `FlutterFramework/Package.swift` contents — wraps `Flutter.xcframework`
  /// as a SwiftPM binary target.
  @visibleForTesting
  static String flutterFrameworkManifest() =>
      '''
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "$_flutterFrameworkPackageName",
    products: [
        .library(name: "$_flutterFrameworkPackageName", targets: ["$_flutterFrameworkPackageName"])
    ],
    targets: [
        .binaryTarget(name: "$_flutterFrameworkPackageName", path: "Flutter.xcframework")
    ]
)
''';

  /// Rewrites Clang-style `-Wl,<argument>...` manifest tokens into the
  /// equivalent arguments accepted by the Swift compiler driver.
  @visibleForTesting
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

  /// Host-side Package.swift fixes for cross builds.
  ///
  /// Includes [normalizeLinkerFlags], plus Windows Swift 6+ CRT imports so
  /// manifests that call `getenv` via removed `MSVCRT` (notably sentry-cocoa)
  /// still compile on the host, and drops the Foundation-only
  /// `String(cString:encoding:)` overload that manifests cannot use.
  @visibleForTesting
  static String normalizeHostManifest(String manifest) {
    var result = normalizeLinkerFlags(manifest);
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
  @visibleForTesting
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
    final importCode = _swiftCodeMask(source);
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
  @visibleForTesting
  static Future<void> normalizeHostSwiftTree(
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
      final normalized = normalizeHostSwiftSource(
        original,
        fallbackSwiftModules: fallbackSwiftModules,
      );
      if (normalized != original) changes[file] = normalized;
    }
    for (final change in changes.entries) {
      await change.key.writeAsString(change.value);
    }
  }

  static List<bool> _swiftCodeMask(String source) {
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

  /// Parses remote `.package(url:)` entries out of a Swift manifest.
  ///
  /// Uses parenthesis balancing so nested forms like
  /// `.upToNextMajor(from: "1.0.0")` are not truncated at the inner `)`.
  @visibleForTesting
  static List<({String? name, String url, String versionArgs, String match})>
  parseUrlPackageDeps(String manifest) {
    final deps =
        <({String? name, String url, String versionArgs, String match})>[];
    var searchFrom = 0;
    final startPattern = RegExp(r'\.package\s*\(');
    while (true) {
      final startMatch = startPattern
          .allMatches(manifest, searchFrom)
          .firstOrNull;
      if (startMatch == null) break;
      final start = startMatch.start;
      final open = startMatch.end - 1; // '('
      final close = _indexOfMatchingParen(manifest, open);
      if (close < 0) break;
      final inner = manifest.substring(open + 1, close);
      final urlMatch = RegExp(r'url:\s*"(?<url>[^"]+)"').firstMatch(inner);
      if (urlMatch == null) {
        searchFrom = close + 1;
        continue;
      }
      final nameMatch = RegExp(r'name:\s*"(?<name>[^"]*)"').firstMatch(inner);
      // Version args are everything in the call except an optional leading
      // name: and the url: clause (order varies slightly across plugins).
      var versionArgs = inner
          .replaceFirst(RegExp(r'name:\s*"[^"]*"\s*,?\s*'), '')
          .replaceFirst(RegExp(r'url:\s*"[^"]+"\s*,?\s*'), '')
          .trim();
      if (versionArgs.endsWith(',')) {
        versionArgs = versionArgs.substring(0, versionArgs.length - 1).trim();
      }
      deps.add((
        name: nameMatch?.namedGroup('name'),
        url: urlMatch.namedGroup('url')!,
        versionArgs: versionArgs,
        match: manifest.substring(start, close + 1),
      ));
      searchFrom = close + 1;
    }
    return deps;
  }

  /// Index of the `)` that closes the `(` at [openIndex], or -1.
  static int _indexOfMatchingParen(String source, int openIndex) {
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

  /// Picks a git ref from SwiftPM version-requirement syntax.
  @visibleForTesting
  static String? gitRefFromVersionArgs(String versionArgs) {
    final exact = RegExp(r'exact:\s*"([^"]+)"').firstMatch(versionArgs);
    if (exact != null) return exact[1];
    final revision = RegExp(r'revision:\s*"([^"]+)"').firstMatch(versionArgs);
    if (revision != null) return revision[1];
    final branch = RegExp(r'branch:\s*"([^"]+)"').firstMatch(versionArgs);
    if (branch != null) return branch[1];
    final from = RegExp(r'from:\s*"([^"]+)"').firstMatch(versionArgs);
    if (from != null) return from[1];
    final range = RegExp(r'"([^"]+)"\s*\.\.<').firstMatch(versionArgs);
    if (range != null) return range[1];
    return null;
  }

  /// Folder name for a vendored checkout of [url] at [ref].
  @visibleForTesting
  static String vendorPackageDirName(String url, String ref) {
    final safeRef = ref.replaceAll(RegExp(r'[^\w.\-]+'), '_');
    return '${packageIdentityFromUrl(url)}@$safeRef';
  }

  /// SwiftPM package identity implied by a git URL (last path segment, no
  /// `.git`). Used as `.package(name:)` so target `package:` references keep
  /// matching after we vendor into a `name@version` directory.
  @visibleForTesting
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

  static List<({int start, int end, String text})> _swiftCalls(
    String source,
    String name,
  ) {
    final calls = <({int start, int end, String text})>[];
    final pattern = RegExp('${RegExp.escape(name)}\\s*\\(');
    for (final match in pattern.allMatches(source)) {
      final close = _indexOfMatchingParen(source, match.end - 1);
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

  static String? _namedString(String call, String name) =>
      RegExp('${RegExp.escape(name)}\\s*:\\s*"([^"]+)"').firstMatch(call)?[1];

  static List<String> _namedStringList(String call, String name) {
    final argument = RegExp('${RegExp.escape(name)}\\s*:').firstMatch(call);
    if (argument == null) return const [];
    final open = call.indexOf('[', argument.end);
    if (open < 0) return const [];
    final close = _indexOfMatchingDelimiter(call, open);
    if (close < 0) return const [];
    return [
      for (final match in RegExp(
        '"([^"]+)"',
      ).allMatches(call.substring(open + 1, close)))
        match[1]!,
    ];
  }

  static int _indexOfMatchingDelimiter(String source, int openIndex) {
    final open = source[openIndex];
    final close = switch (open) {
      '(' => ')',
      '[' => ']',
      '{' => '}',
      _ => '',
    };
    if (close.isEmpty) return -1;
    final code = _swiftCodeMask(source);
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

  static ({int open, int close})? _fallbackBlock(String manifest) {
    final marker = manifest.indexOf('products.removeAll()');
    if (marker < 0) return null;
    final open = manifest.lastIndexOf('{', marker);
    if (open < 0) return null;
    final close = _indexOfMatchingDelimiter(manifest, open);
    return close < 0 ? null : (open: open, close: close);
  }

  static Set<String> _consumedProducts(String manifest, String package) {
    final products = <String>{};
    for (final call in _swiftCalls(manifest, '.product')) {
      if (_namedString(call.text, 'package') == package) {
        final name = _namedString(call.text, 'name');
        if (name != null) products.add(name);
      }
    }
    return products;
  }

  static List<String> _topLevelModuleNames(String moduleMap) {
    final code = _swiftCodeMask(moduleMap);
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

  static ({int start, int open, int close})? _moduleBlock(
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
    final close = _indexOfMatchingDelimiter(moduleMap, open);
    return close < 0
        ? null
        : (start: declaration.start, open: open, close: close);
  }

  static List<({String path, bool directory})> _directModuleHeaders(
    String moduleMap,
    ({int start, int open, int close}) block,
  ) {
    final code = _swiftCodeMask(moduleMap);
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

  static int _braceDepthAt(String source, int offset) {
    final code = _swiftCodeMask(source);
    var depth = 0;
    for (var i = 0; i < offset; i++) {
      if (!code[i]) continue;
      if (source[i] == '{') depth++;
      if (source[i] == '}') depth--;
    }
    return depth;
  }

  static List<String> _directNestedModules(
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
      if (_braceDepthAt(moduleMap, match.start) != 1) continue;
      final open = moduleMap.indexOf('{', match.start);
      final close = _indexOfMatchingDelimiter(moduleMap, open);
      if (close < 0 || close > parent.close) continue;
      nested.add(moduleMap.substring(match.start, close + 1).trim());
    }
    return nested;
  }

  static bool _ignoredPackageEvidencePath(String packageDir, String path) {
    final relative = p.relative(path, from: packageDir);
    final parts = p.split(relative);
    return parts.any(
      (part) => part == '.git' || part == '.build' || part == '.xcross',
    );
  }

  static String _resolveModuleReference(
    String packageDir,
    String reference, {
    required bool directory,
  }) {
    final normalized = p.normalize(reference);
    final matches = <String>[];
    for (final entity in Directory(
      packageDir,
    ).listSync(recursive: true, followLinks: false)) {
      if (_ignoredPackageEvidencePath(packageDir, entity.path)) continue;
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

  static String _absoluteNestedModuleHeaders(String packageDir, String nested) {
    final result = nested.replaceAllMapped(
      RegExp(r'((?:umbrella\s+)?header\s+)"([^"]+)"'),
      (match) {
        final resolved = _resolveModuleReference(
          packageDir,
          match[2]!,
          directory: false,
        );
        return '${match[1]}"${_swiftPath(resolved)}"';
      },
    );
    return result.replaceAllMapped(RegExp(r'(umbrella\s+)"([^"]+)"'), (match) {
      final resolved = _resolveModuleReference(
        packageDir,
        match[2]!,
        directory: true,
      );
      return '${match[1]}"${_swiftPath(resolved)}"';
    });
  }

  /// Adds a dependency-scoped Clang module when a source fallback preserves
  /// its implementation modules but no longer emits a consumed binary module.
  @visibleForTesting
  static Future<String> synthesizeBinaryFallbackCompatibility(
    String manifest, {
    required String packageDir,
    required Set<String> consumedProducts,
    Map<String, List<String>>? fallbackSwiftModules,
  }) async {
    var result = manifest;
    for (final product in consumedProducts) {
      result = await _synthesizeBinaryFallbackProduct(
        result,
        packageDir: packageDir,
        product: product,
        fallbackSwiftModules: fallbackSwiftModules,
      );
    }
    return result;
  }

  static Future<String> _synthesizeBinaryFallbackProduct(
    String manifest, {
    required String packageDir,
    required String product,
    Map<String, List<String>>? fallbackSwiftModules,
  }) async {
    final fallback = _fallbackBlock(manifest);
    if (fallback == null) return manifest;
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(product)) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM Clang module "$product": the binary '
        'product name is not a Clang module identifier.',
      );
    }

    final normalManifest = manifest.substring(0, fallback.open);
    final binaryTargets = {
      for (final call in _swiftCalls(normalManifest, '.binaryTarget'))
        if (_namedString(call.text, 'name') case final String name) name,
    };
    final binaryBacked = _swiftCalls(normalManifest, '.library').any(
      (call) =>
          _namedString(call.text, 'name') == product &&
          _namedStringList(call.text, 'targets').any(binaryTargets.contains),
    );
    if (!binaryBacked) return manifest;

    final blockText = manifest.substring(fallback.open + 1, fallback.close);
    final synthetic = '_xcross_$product';
    final productCalls = _swiftCalls(blockText, '.library');
    final fallbackProducts = [
      for (final call in productCalls)
        (
          call: call,
          name: _namedString(call.text, 'name'),
          targets: _namedStringList(call.text, 'targets'),
        ),
    ].where((entry) => entry.name != null && entry.targets.isNotEmpty).toList();
    final sourceProducts = [
      for (final entry in fallbackProducts)
        (
          call: entry.call,
          name: entry.name,
          targets: entry.targets.where((name) => name != synthetic).toList(),
        ),
    ].where((entry) => entry.targets.isNotEmpty).toList();
    final matchingProducts = sourceProducts
        .where((entry) => entry.name == product)
        .toList();
    final sourceProduct = matchingProducts.length == 1
        ? matchingProducts.single
        : sourceProducts.length == 1
        ? sourceProducts.single
        : null;
    if (sourceProduct == null) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM module "$product": the fallback product '
        'is ambiguous (${sourceProducts.map((entry) => entry.name).join(', ')}).',
      );
    }

    final targetCalls = _swiftCalls(blockText, '.target');
    final targets =
        <
          String,
          ({
            String call,
            List<String> dependencies,
            String path,
            String? headers,
            List<String> sources,
            List<String> excludes,
          })
        >{};
    for (final call in targetCalls) {
      final name = _namedString(call.text, 'name');
      if (name == null) continue;
      targets[name] = (
        call: call.text,
        dependencies: _namedStringList(call.text, 'dependencies'),
        path: _namedString(call.text, 'path') ?? p.join('Sources', name),
        headers: _namedString(call.text, 'publicHeadersPath'),
        sources: _namedStringList(call.text, 'sources'),
        excludes: _namedStringList(call.text, 'exclude'),
      );
    }

    final closure = <String>[];
    final visiting = <String>{};
    void visit(String name) {
      if (name == synthetic ||
          !targets.containsKey(name) ||
          !visiting.add(name)) {
        return;
      }
      closure.add(name);
      for (final dependency in targets[name]!.dependencies) {
        visit(dependency);
      }
    }

    for (final target in sourceProduct.targets) {
      visit(target);
    }
    if (closure.isEmpty) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM module "$product": its fallback target '
        'closure is empty.',
      );
    }

    final headerTargets =
        <({String name, String root, List<String> modules})>[];
    for (final name in closure) {
      final target = targets[name]!;
      if (target.headers == null) continue;
      final root = p.normalize(p.join(packageDir, target.path, target.headers));
      final moduleMap = File(p.join(root, 'module.modulemap'));
      final modules = moduleMap.existsSync()
          ? _topLevelModuleNames(moduleMap.readAsStringSync())
          : [name];
      if (modules.contains(product)) return manifest;
      if (modules.isNotEmpty) {
        headerTargets.add((name: name, root: root, modules: modules));
      }
    }

    final canonicalMaps = <({File file, String text})>[];
    for (final entity in Directory(
      packageDir,
    ).listSync(recursive: true, followLinks: false)) {
      if (entity is! File ||
          _ignoredPackageEvidencePath(packageDir, entity.path) ||
          !(p.basename(entity.path) == 'module.modulemap' ||
              p.basename(entity.path).endsWith('.modulemap'))) {
        continue;
      }
      final text = entity.readAsStringSync();
      if (_moduleBlock(text, product) != null) {
        canonicalMaps.add((file: entity, text: text));
      }
    }
    if (canonicalMaps.length != 1) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM module "$product": expected one canonical '
        'module map, found ${canonicalMaps.length}.',
      );
    }
    final canonical = canonicalMaps.single;
    final canonicalBlock = _moduleBlock(canonical.text, product)!;
    final publicHeaders = [
      for (final header in _directModuleHeaders(canonical.text, canonicalBlock))
        _resolveModuleReference(
          packageDir,
          header.path,
          directory: header.directory,
        ),
    ];
    final publicModules = headerTargets.where((target) {
      return publicHeaders.every(
        (header) =>
            p.equals(header, target.root) || p.isWithin(target.root, header),
      );
    }).toList();
    if (publicModules.length != 1 || publicModules.single.modules.length != 1) {
      throw FlutterBuildError(
        'Cannot synthesize SwiftPM module "$product": the fallback public '
        'header module is ambiguous.',
      );
    }

    final swiftModules = <String>[];
    for (final name in closure) {
      final target = targets[name]!;
      final root = Directory(p.join(packageDir, target.path));
      if (!root.existsSync()) continue;
      final sourceRoots = target.sources.isEmpty
          ? [root.path]
          : [for (final source in target.sources) p.join(root.path, source)];
      final hasSwift = sourceRoots.any((sourceRoot) {
        final directory = Directory(sourceRoot);
        if (directory.existsSync()) {
          return directory.listSync(recursive: true, followLinks: false).any((
            entity,
          ) {
            if (entity is! File || !entity.path.endsWith('.swift')) {
              return false;
            }
            final relative = p.relative(entity.path, from: root.path);
            return !target.excludes.any(
              (excluded) =>
                  p.equals(relative, excluded) ||
                  p.isWithin(excluded, relative),
            );
          });
        }
        return File(sourceRoot).path.endsWith('.swift') &&
            File(sourceRoot).existsSync();
      });
      if (hasSwift) swiftModules.add(name);
    }
    if (fallbackSwiftModules != null) {
      fallbackSwiftModules[product] = swiftModules;
    }

    final compatibilityDir = p.join(packageDir, '.xcross', synthetic);
    final includeDir = p.join(compatibilityDir, 'include');
    final nested = [
      for (final module in _directNestedModules(canonical.text, canonicalBlock))
        _absoluteNestedModuleHeaders(packageDir, module),
    ];
    final nestedNames = [
      for (final module in nested) ..._topLevelModuleNames(module),
    ];
    final indentedNested = nested
        .map(
          (module) => module
              .replaceFirst(RegExp(r'\{'), '{\n  header "$product.h"')
              .split('\n')
              .map((line) => '  $line')
              .join('\n'),
        )
        .join('\n');
    final moduleMap = StringBuffer()
      ..writeln('module $product {')
      ..writeln('  header "$product.h"')
      ..writeln('  export *');
    for (final name in nestedNames) {
      moduleMap.writeln('  export $name');
    }
    if (indentedNested.isNotEmpty) moduleMap.writeln(indentedNested);
    moduleMap.writeln('}');

    await Directory(includeDir).create(recursive: true);
    final shim = StringBuffer()
      ..writeln('@import ${publicModules.single.modules.single};');
    // The fallback's Swift half completes the Objective-C surface: the
    // headers refer to types the Swift target declares, so a consumer that
    // sees the headers alone imports those declarations as incomplete and
    // loses every member mentioning them. Swift emits an Objective-C
    // interop header for such a target, and SwiftPM puts it on the include
    // path of the targets that depend on it. Prefer that header, because a
    // bare `@import` of a Swift module only resolves once that module is
    // built, which is not the case while Swift builds this very module.
    for (final module in swiftModules) {
      shim
        ..writeln('#if __has_include("$module-Swift.h")')
        ..writeln('#import "$module-Swift.h"')
        ..writeln('#elif !defined(__swift__)')
        ..writeln('@import $module;')
        ..writeln('#endif');
    }
    await _writeStable(p.join(includeDir, '$product.h'), shim.toString());
    await _writeStable(
      p.join(includeDir, 'module.modulemap'),
      moduleMap.toString(),
    );
    await _writeStable(
      p.join(compatibilityDir, '$synthetic.m'),
      '#import "$product.h"\n',
    );

    final syntheticCount = fallbackProducts
        .singleWhere((entry) => entry.call.start == sourceProduct.call.start)
        .targets
        .where((name) => name == synthetic)
        .length;
    var rewrittenBlock = blockText;
    if (sourceProduct.name == product && syntheticCount != 1) {
      final targetsPattern = RegExp(r'targets\s*:\s*\[([^\]]*)\]');
      final normalizedTargets = [
        ...sourceProduct.targets,
        synthetic,
      ].map((name) => '"$name"').join(', ');
      final updatedProduct = sourceProduct.call.text.replaceFirst(
        targetsPattern,
        'targets: [$normalizedTargets]',
      );
      rewrittenBlock = rewrittenBlock.replaceRange(
        sourceProduct.call.start,
        sourceProduct.call.end,
        updatedProduct,
      );
    }
    final dependencyList = closure.map((name) => '"$name"').join(', ');
    final additions = StringBuffer();
    if (sourceProduct.name != product &&
        !fallbackProducts.any((entry) => entry.name == product)) {
      additions.writeln(
        '    products.append(.library(name: "$product", '
        'targets: ["$synthetic"]))',
      );
    }
    if (!targets.containsKey(synthetic)) {
      additions.writeln(
        '    targets.append(.target(name: "$synthetic", '
        'dependencies: [$dependencyList], path: ".xcross/$synthetic", '
        'publicHeadersPath: "include"))',
      );
    }
    rewrittenBlock = '${rewrittenBlock.trimRight()}\n$additions';
    return manifest.replaceRange(
      fallback.open + 1,
      fallback.close,
      rewrittenBlock,
    );
  }

  /// Clones each `.package(url:)` dependency under [vendorDir], normalizes its
  /// host manifests, and rewrites the plugin manifest to `.package(path:)`.
  @visibleForTesting
  static Future<String> vendorUrlPackagesAsPathDeps(
    String manifest, {
    required String vendorDir,
    Map<String, List<String>>? fallbackSwiftModules,
    Future<String> Function(String name)? locateTool,
    Future<void> Function(
      String git,
      String url,
      String ref,
      String destination,
    )?
    clonePackage,
  }) async {
    final deps = parseUrlPackageDeps(manifest);
    if (deps.isEmpty) return manifest;

    final locate = locateTool ?? ProcessRunner.locateTool;
    late final String git;
    try {
      git = await locate('git');
    } on CliError {
      throw FlutterBuildError(
        'Git is required on Windows to vendor SwiftPM URL dependencies '
        '(e.g. sentry-cocoa). Install Git and ensure it is on PATH.',
      );
    }

    final clone = clonePackage ?? _cloneGitPackage;

    var result = manifest;
    final seen = <String>{};
    for (final dep in deps) {
      final ref = gitRefFromVersionArgs(dep.versionArgs);
      if (ref == null) {
        throw FlutterBuildError(
          'Cannot vendor SwiftPM dependency ${dep.url}: unsupported version '
          'requirement "${dep.versionArgs}".',
        );
      }
      final dirName = vendorPackageDirName(dep.url, ref);
      // Always set name: — without it SwiftPM uses the directory basename
      // (`pkg@1.2.3`), which breaks `.product(..., package: "pkg")`.
      final identity = dep.name ?? packageIdentityFromUrl(dep.url);
      if (seen.add(dirName)) {
        final destination = p.join(vendorDir, dirName);
        await clone(git, dep.url, ref, destination);
        await _normalizeVendoredPackageManifests(
          destination,
          consumedProducts: _consumedProducts(manifest, identity),
          fallbackSwiftModules: fallbackSwiftModules,
        );
      }
      final pathDep =
          '.package(name: "$identity", '
          'path: "${_swiftPath(p.join(vendorDir, dirName))}")';
      result = result.replaceFirst(dep.match, pathDep);
    }
    return result;
  }

  /// Replaces mode-120000 checkout placeholders produced by Git for Windows
  /// with hard links to files or copies of directory targets.
  @visibleForTesting
  static Future<void> materializeCheckoutSymlinks(
    String scratchPath, {
    String git = 'git',
  }) async {
    final checkouts = Directory(p.join(scratchPath, 'checkouts'));
    if (!checkouts.existsSync()) return;
    await for (final repo in checkouts.list(followLinks: false)) {
      if (repo is! Directory) continue;
      final index = await ProcessRunner.run(git, [
        '-C',
        repo.path,
        'ls-files',
        '-s',
        '-z',
      ]);
      if (index.exitCode != 0) {
        throw FlutterBuildError(
          'Could not inspect SwiftPM checkout ${repo.path}: ${index.stderr}',
        );
      }
      await _materializeGitSymlinks(repo.path, index.stdout, git);
    }
  }

  static Future<void> _materializeGitSymlinks(
    String repoPath,
    String index,
    String git,
  ) async {
    final root = p.normalize(p.absolute(repoPath));
    final links = <String, String>{};
    for (final record in index.split('\u0000')) {
      final match = RegExp(
        r'^120000 ([0-9a-f]+) \d+\t(.*)$',
      ).firstMatch(record);
      if (match != null) {
        links[p.normalize(p.join(root, match[2]))] = match[1]!;
      }
    }

    final targets = <String, String>{};
    for (final link in links.entries) {
      final blob = await ProcessRunner.run(git, [
        '-C',
        repoPath,
        'cat-file',
        'blob',
        link.value,
      ]);
      if (blob.exitCode != 0) {
        throw FlutterBuildError(
          'Could not read symlink target in SwiftPM checkout $repoPath: '
          '${blob.stderr}',
        );
      }
      targets[link.key] = blob.stdout.replaceFirst(RegExp(r'[\r\n]+$'), '');
    }

    final resolved = <String, String>{};
    String resolve(String source, Set<String> chain) {
      if (!chain.add(source)) {
        throw FlutterBuildError('Symlink cycle in SwiftPM checkout: $source');
      }
      final targetText = targets[source]!;
      if (p.isAbsolute(targetText)) {
        throw FlutterBuildError(
          'Symlink escapes SwiftPM checkout: $source -> $targetText',
        );
      }
      final target = p.normalize(p.absolute(p.dirname(source), targetText));
      if (target != root && !p.isWithin(root, target)) {
        throw FlutterBuildError(
          'Symlink escapes SwiftPM checkout: $source -> $targetText',
        );
      }
      final result = links.containsKey(target)
          ? resolve(target, chain)
          : target;
      chain.remove(source);
      return result;
    }

    for (final link in links.keys) {
      resolved[link] = resolve(link, <String>{});
    }

    final materializing = <String>{};
    final materialized = <String>{};
    Future<void> materialize(String link) async {
      if (materialized.contains(link)) return;
      if (!materializing.add(link)) {
        throw FlutterBuildError('Symlink cycle in SwiftPM checkout: $link');
      }
      final target = resolved[link]!;
      if (Directory(target).existsSync()) {
        for (final nested in links.keys) {
          if (p.isWithin(target, nested)) await materialize(nested);
        }
      }
      // Re-materializing an already-correct placeholder would refresh its
      // timestamp and rebuild every dependent, so each shape is checked
      // before it is rewritten.
      if (Directory(target).existsSync()) {
        await _clearPlaceholderAttributes(link);
        await _deleteUnless(link, FileSystemEntityType.directory);
        await _syncDirectory(target, link);
      } else if (File(target).existsSync()) {
        await _materializeFileLink(link, target);
      } else {
        throw FlutterBuildError(
          'Symlink target does not exist in SwiftPM checkout: $link -> $target',
        );
      }
      materializing.remove(link);
      materialized.add(link);
    }

    for (final link in links.keys) {
      await materialize(link);
    }
  }

  /// Windows source for a header placeholder that keeps one Clang file
  /// identity, or null when [link] is not a header.
  ///
  /// Packages publish umbrella directories by symlinking headers to a
  /// source tree, so the same header is reachable under two paths. Clang
  /// suppresses the second inclusion by file identity, and on POSIX a
  /// symlink shares one. Windows checkouts cannot use symlinks without
  /// elevation, and Clang treats the two names of a hard link as separate
  /// identities, so a header without an include guard is parsed twice and
  /// every declaration in it collides with itself. Forwarding to the
  /// target instead leaves exactly one file to parse under either path.
  static String? _headerForwarder(String link, String target) {
    const headerExtensions = {'.h', '.hh', '.hpp', '.hxx', '.h++'};
    if (!headerExtensions.contains(p.extension(link).toLowerCase())) {
      return null;
    }
    final relative = p.relative(target, from: p.dirname(link));
    return '#include "${relative.replaceAll(r'\', '/')}"\n';
  }

  /// Replaces a file placeholder with its materialized form: a forwarding
  /// header, a hard link on Windows, or a plain copy elsewhere. A
  /// placeholder whose content already matches is left untouched.
  static Future<void> _materializeFileLink(String link, String target) async {
    if (!Platform.isWindows) {
      await _syncFile(File(target), link);
      return;
    }
    final forwarder = _headerForwarder(link, target);
    final expected = forwarder != null
        ? utf8.encode(forwarder)
        : await File(target).readAsBytes();
    final existing = File(link);
    if (existing.existsSync() &&
        _sameBytes(await existing.readAsBytes(), expected)) {
      return;
    }
    await _clearPlaceholderAttributes(link);
    await _deleteEntity(link);
    if (forwarder != null) {
      await existing.writeAsString(forwarder);
      return;
    }
    final result = await Process.run('cmd.exe', [
      '/d',
      '/c',
      'mklink',
      '/H',
      link,
      target,
    ]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Could not create hard link: ${result.stderr}',
        link,
      );
    }
  }

  /// Git for Windows checks out symlink placeholders read-only.
  static Future<void> _clearPlaceholderAttributes(String path) async {
    if (!Platform.isWindows) return;
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final result = await Process.run('attrib', ['-R', path]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Could not clear read-only checkout placeholder: ${result.stderr}',
        path,
      );
    }
  }

  static Future<void> _cloneGitPackage(
    String git,
    String url,
    String ref,
    String destination,
  ) async {
    final destDir = Directory(destination);
    final environment = swiftProcessEnvironment(windows: Platform.isWindows);
    if (File(p.join(destination, '.git')).existsSync() ||
        Directory(p.join(destination, '.git')).existsSync()) {
      final head = await ProcessRunner.run(git, [
        '-C',
        destination,
        'rev-parse',
        '--verify',
        'HEAD',
      ], environment: environment);
      if (head.exitCode == 0) return;
    }
    await _deleteEntity(destination);
    await destDir.parent.create(recursive: true);

    // Shallow clone of the pinned tag/branch. Falls back to a full clone +
    // checkout when the ref is not advertised as a remote HEAD (some hosts).
    final shallow = await ProcessRunner.run(git, [
      'clone',
      '--depth',
      '1',
      '--branch',
      ref,
      url,
      destination,
    ], environment: environment);
    if (shallow.exitCode == 0) return;

    await _deleteEntity(destination);
    await ProcessRunner.runChecked(
      git,
      ['clone', url, destination],
      environment: environment,
      label: 'git clone $url',
    );
    await ProcessRunner.runChecked(
      git,
      ['-C', destination, 'checkout', ref],
      environment: environment,
      label: 'git checkout $ref',
    );
  }

  static Future<void> _normalizeVendoredPackageManifests(
    String packageDir, {
    required Set<String> consumedProducts,
    Map<String, List<String>>? fallbackSwiftModules,
  }) async {
    await for (final entity in Directory(packageDir).list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name != 'Package.swift' &&
          !(name.startsWith('Package@') && name.endsWith('.swift'))) {
        continue;
      }
      final original = await entity.readAsString();
      final normalized = await synthesizeBinaryFallbackCompatibility(
        normalizeHostManifest(original),
        packageDir: packageDir,
        consumedProducts: consumedProducts,
        fallbackSwiftModules: fallbackSwiftModules,
      );
      if (normalized != original) {
        await entity.writeAsString(normalized);
      }
    }
  }

  /// `Plugins/Package.swift` contents — aggregates every plugin's SPM package
  /// into one dynamic library product depending on [frameworkDir]'s
  /// `FlutterFramework` package plus every entry in [plugins].
  @visibleForTesting
  static String pluginsManifest(
    List<IosPlugin> plugins,
    String frameworkDir, {
    required IosDeploymentTarget deploymentTarget,
    Map<String, String>? pluginPackageDirs,
  }) {
    final dependencies = StringBuffer()
      ..writeln(
        '        .package(name: "$_flutterFrameworkPackageName", '
        'path: "${_swiftPath(frameworkDir)}"),',
      );
    for (final plugin in plugins) {
      final packageDir =
          pluginPackageDirs?[plugin.name] ?? plugin.swiftPackageDir;
      dependencies.writeln(
        '        .package(name: "${plugin.name}", '
        'path: "${_swiftPath(packageDir)}"),',
      );
    }

    final targetDependencies = StringBuffer()
      ..writeln(
        '                .product(name: "$_flutterFrameworkPackageName", '
        'package: "$_flutterFrameworkPackageName"),',
      );
    for (final plugin in plugins) {
      targetDependencies.writeln(
        '                .product(name: "${_hyphenate(plugin.name)}", '
        'package: "${plugin.name}"),',
      );
    }

    return '''
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "$_pluginsProductName",
    platforms: [
        .iOS("${deploymentTarget.version}")
    ],
    products: [
        .library(name: "$_pluginsProductName", type: .dynamic, targets: ["$_pluginsProductName"])
    ],
    dependencies: [
$dependencies    ],
    targets: [
        .target(
            name: "$_pluginsProductName",
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
  @visibleForTesting
  static String registrantSource(List<IosPlugin> plugins) {
    final imports = StringBuffer();
    final registrations = StringBuffer();
    for (final plugin in plugins) {
      final pluginClass = plugin.pluginClassIos;
      if (pluginClass == null) continue;
      imports.writeln('import ${plugin.name}');
      registrations.writeln('''
    if let registrar = registry.registrar(forPlugin: "$pluginClass") {
        $pluginClass.register(with: registrar)
    }''');
    }

    return '''
//
// Generated file. Do not edit.
//
import Flutter
import UIKit
$imports
@_cdecl("${GeneratedPluginsConstants.registrantSymbol}")
public func xcrossRegisterGeneratedPlugins(_ registry: FlutterPluginRegistry) {
$registrations}
''';
  }

  /// Writes [content] to [path] only when it differs.
  ///
  /// SwiftPM invalidates on timestamps, so rewriting identical generated
  /// files would recompile the whole plugin graph on every run.
  static Future<void> _writeStable(String path, String content) async {
    final file = File(path);
    if (file.existsSync() && await file.readAsString() == content) return;
    await file.writeAsString(content);
  }

  /// Copies [source] to [destination], applying [transform] when it elects
  /// the file, and skipping the write when the destination already matches.
  ///
  /// The skip preserves destination timestamps, which SwiftPM invalidates
  /// on, so unchanged files stay warm in its incremental state. Files the
  /// transform declines are copied as raw bytes, so binaries are never
  /// decoded.
  static Future<void> _syncFile(
    File source,
    String destination, {
    _SourceTransform? transform,
  }) async {
    List<int> bytes = await source.readAsBytes();
    final rewrite = transform?.call(source.path);
    if (rewrite != null) {
      bytes = utf8.encode(rewrite(utf8.decode(bytes)));
    }
    final existing = File(destination);
    if (existing.existsSync() &&
        _sameBytes(await existing.readAsBytes(), bytes)) {
      return;
    }
    await existing.writeAsBytes(bytes);
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Mirrors [source] into [destination], resolving links to their
  /// targets, rewriting only differing files, and pruning entries the
  /// source no longer has. [preserve] names top-level entries the caller
  /// owns; [excludedSourcePath] guards against copying a destination that
  /// lives inside its own source.
  static Future<void> _syncDirectory(
    String source,
    String destination, {
    Set<String> preserve = const {},
    String? excludedSourcePath,
    _SourceTransform? transform,
  }) async {
    final absoluteSource = p.normalize(p.absolute(source));
    final absoluteDestination = p.normalize(p.absolute(destination));
    if (p.equals(absoluteSource, absoluteDestination)) return;
    final excluded = excludedSourcePath == null
        ? (p.isWithin(absoluteSource, absoluteDestination)
              ? absoluteDestination
              : null)
        : p.normalize(p.absolute(excludedSourcePath));
    await Directory(destination).create(recursive: true);

    final expected = <String>{...preserve};
    await for (final entity in Directory(source).list(followLinks: false)) {
      if (excluded != null &&
          p.equals(p.normalize(p.absolute(entity.path)), excluded)) {
        continue;
      }
      final name = p.basename(entity.path);
      if (preserve.contains(name)) continue;
      expected.add(name);
      final destinationPath = p.join(destination, name);
      final resolved = entity is Link
          ? entity.resolveSymbolicLinksSync()
          : entity.path;
      if (Directory(resolved).existsSync()) {
        await _deleteUnless(destinationPath, FileSystemEntityType.directory);
        await _syncDirectory(
          resolved,
          destinationPath,
          excludedSourcePath: excluded,
          transform: transform,
        );
      } else {
        await _deleteUnless(destinationPath, FileSystemEntityType.file);
        await _syncFile(File(resolved), destinationPath, transform: transform);
      }
    }

    await for (final entity in Directory(
      destination,
    ).list(followLinks: false)) {
      if (!expected.contains(p.basename(entity.path))) {
        await _deleteEntity(entity.path);
      }
    }
  }

  /// Deletes whatever occupies [path] unless it already is a [keep] entry,
  /// so links can become directories and vice versa without stale state.
  static Future<void> _deleteUnless(
    String path,
    FileSystemEntityType keep,
  ) async {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound || type == keep) return;
    await _deleteEntity(path);
  }

  static Future<void> _deleteEntity(String path) async {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      await Link(path).delete();
    } else if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else if (type == FileSystemEntityType.file) {
      await File(path).delete();
    }
  }

  /// Makes the staged Swift package appear directly beside FlutterFramework,
  /// so every plugin's conventional `../FlutterFramework` dependency resolves
  /// to the same package path. Directory junctions avoid Windows symlink
  /// privilege requirements.
  static Future<void> _createDirectoryAlias(String alias, String target) async {
    await _deleteEntity(alias);
    if (Platform.isWindows) {
      final result = await Process.run('cmd.exe', [
        '/c',
        'mklink',
        '/J',
        p.windows.normalize(alias),
        p.windows.normalize(p.absolute(target)),
      ]);
      if (result.exitCode != 0) {
        throw FileSystemException(
          'Could not create plugin package junction: ${result.stderr}',
          alias,
        );
      }
      return;
    }

    await Link(alias).create(p.relative(target, from: p.dirname(alias)));
  }

  static String _jsonPath(String path) => path.replaceAll(r'\', '/');

  /// Forward-slash-safe absolute path for interpolation into a Swift string
  /// literal on every host.
  static String _swiftPath(String path) => _jsonPath(p.absolute(path));

  /// A pub package name with underscores replaced by hyphens — SwiftPM's own
  /// convention for a plugin's SPM library product name (used as the
  /// CFBundleIdentifier for dynamic products, which can't contain
  /// underscores). The `package:` argument stays underscored, matching the
  /// plugin's own unmodified `Package(name: ...)`.
  static String _hyphenate(String name) => name.replaceAll('_', '-');
}

/// Elects and rewrites file content during a directory sync: returns null
/// to copy [path] verbatim, or a rewriter for its decoded text.
typedef _SourceTransform =
    String Function(String content)? Function(String path);
