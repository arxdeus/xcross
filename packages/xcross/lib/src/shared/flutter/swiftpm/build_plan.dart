import 'dart:async';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:open_apple_macros/shared/open_apple_macros_server.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/ios_linker_compatibility.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';

@internal
const String flutterFrameworkPackageName = 'FlutterFramework';
@internal
const String pluginsProductName = 'FlutterPluginsGenerated';

@internal
final class SwiftPmBuildPlan<T extends PlatformHostInterface> {
  SwiftPmBuildPlan({
    required this.filesystem,
    required this.hostPolicy,
    required this.runner,
    required this.macroServer,
  });
  final SwiftPmFilesystem<T> filesystem;
  final SwiftPmHostPolicy hostPolicy;
  final ProcessRunner<T> runner;
  final OpenAppleMacrosServer<T> macroServer;

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

  Future<List<String>> macroServerArguments({
    required String cacheRoot,
    required String swiftBuild,
    required Map<String, String> environment,
  }) async {
    final driver = runner.host.paths.context.join(
      runner.host.paths.context.dirname(swiftBuild),
      runner.hostExecutableName('swiftc'),
    );
    final build = await macroServer.ensure(
      cacheRoot: cacheRoot,
      swiftDriver: SwiftToolCommand(driver),
      swiftBuild: SwiftToolCommand(swiftBuild, hostPolicy.buildPrefix),
      environment: environment,
    );
    return build.swiftBuildArguments;
  }

  Future<String> writeObjectiveCCompatibilityHeader(String outputDir) async {
    final path = p.join(outputDir, '.xcross', 'objective-c-compatibility.h');
    await filesystem.artifactFileSystem
        .directory(p.dirname(path))
        .create(recursive: true);
    await filesystem.writeStable(
      path,
      '#ifdef __OBJC__\n#import <Foundation/Foundation.h>\n#endif\n',
    );
    return path;
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
    List<String> macroServerArguments = const [],
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
    ...macroServerArguments,
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
    if (linkerPath != null) ...hostPolicy.linkerPathArguments(linkerPath),
  ];
}
