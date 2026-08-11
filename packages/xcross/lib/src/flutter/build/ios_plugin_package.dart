import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_plugins.dart';
import 'package:xcross/src/flutter/build/macho_dylib_rewriter.dart';
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
    final toolsetPath = await writeToolset(
      outputDir: outputDir,
      linkerPath: linker,
      cCompilerPath: Platform.isWindows
          ? await DarwinSdk.resolveDarwinClang(sdk)
          : null,
      cxxCompilerPath: Platform.isWindows
          ? await DarwinSdk.resolveDarwinClang(sdk, name: 'clang++')
          : null,
    );
    await ProcessRunner.runChecked(
      swift,
      swiftBuildArguments(
        pluginsDir: pluginsDir,
        scratchPath: scratchPath,
        swiftSdksPath: p.dirname(sdk.swiftSdkPath),
        iosSdk: sdk.iPhoneOSSdk(),
        flutterFrameworkSlice: flutterFrameworkSlice,
        toolsetPath: toolsetPath,
        // Windows gets the same override from the toolset's `linker`.
        linkerPath: Platform.isWindows ? null : linker,
      ),
      inheritStdio: Log.isVerbose,
      label: 'swift build',
    );
  }

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

    final toolsetFile = File(p.join(outputDir, 'xcross-toolset.json'));
    await toolsetFile.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(toolset)}\n',
    );
    return toolsetFile.path;
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
  @visibleForTesting
  static Future<void> writeGeneratedPackages({
    required String outputDir,
    required List<IosPlugin> plugins,
    required String flutterXcframework,
    required IosDeploymentTarget deploymentTarget,
    bool? copyFlutterXcframework,
  }) async {
    final packagesDir = p.join(outputDir, 'Packages');
    final frameworkDir = p.join(packagesDir, _flutterFrameworkPackageName);
    final pluginsDir = p.join(outputDir, 'Plugins');

    await Directory(packagesDir).create(recursive: true);

    final pluginPackageDirs = <String, String>{};
    for (final plugin in plugins) {
      final packageAlias = p.join(packagesDir, plugin.name);
      await _createDirectoryAlias(packageAlias, plugin.swiftPackageDir);
      pluginPackageDirs[plugin.name] = packageAlias;
    }

    await _writeFlutterFrameworkPackage(
      frameworkDir: frameworkDir,
      flutterXcframework: flutterXcframework,
      copyFlutterXcframework: copyFlutterXcframework ?? Platform.isWindows,
    );
    await _writePluginsPackage(
      pluginsDir: pluginsDir,
      frameworkDir: frameworkDir,
      plugins: plugins,
      pluginPackageDirs: pluginPackageDirs,
      deploymentTarget: deploymentTarget,
    );
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
    await File(
      p.join(frameworkDir, 'Package.swift'),
    ).writeAsString(flutterFrameworkManifest());

    final frameworkPath = p.join(frameworkDir, 'Flutter.xcframework');
    await _deleteEntity(frameworkPath);
    if (copyFlutterXcframework) {
      await _copyDirectory(flutterXcframework, frameworkPath);
    } else {
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

    await File(p.join(pluginsDir, 'Package.swift')).writeAsString(
      pluginsManifest(
        plugins,
        frameworkDir,
        pluginPackageDirs: pluginPackageDirs,
        deploymentTarget: deploymentTarget,
      ),
    );

    await File(
      p.join(sourcesDir, 'GeneratedPluginRegistrant.swift'),
    ).writeAsString(registrantSource(plugins));
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

  /// `GeneratedPluginRegistrant.swift` contents — imports every plugin and
  /// registers each one that has a non-null `pluginClassIos`. Plugins with no
  /// `pluginClassIos` (facade/pure-Dart/FFI-only packages) are imported but
  /// silently skipped in the registration body, since they have nothing to
  /// register.
  @visibleForTesting
  static String registrantSource(List<IosPlugin> plugins) {
    final imports = StringBuffer();
    for (final plugin in plugins) {
      imports.writeln('import ${plugin.name}');
    }

    final registrations = StringBuffer();
    for (final plugin in plugins) {
      final pluginClass = plugin.pluginClassIos;
      if (pluginClass == null) continue;
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

  static Future<void> _copyDirectory(String source, String destination) async {
    await Directory(destination).create(recursive: true);
    await for (final entity in Directory(source).list(followLinks: false)) {
      final destinationPath = p.join(destination, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectory(entity.path, destinationPath);
      } else if (entity is File) {
        await entity.copy(destinationPath);
      } else if (entity is Link) {
        final target = entity.resolveSymbolicLinksSync();
        if (Directory(target).existsSync()) {
          await _copyDirectory(target, destinationPath);
        } else {
          await File(target).copy(destinationPath);
        }
      }
    }
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
