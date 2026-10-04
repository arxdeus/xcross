import 'dart:async';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/ios_linker_compatibility.dart';
import 'package:xcross/src/flutter/build/preview_macro_stub_source.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/preview_macro_compiler.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmBuildPlan<T extends PlatformHostInterface> {
  SwiftPmBuildPlan({
    required this.filesystem,
    required this.hostPolicy,
    required this.runner,
    required this.previewCompiler,
  });
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
  Future<String> writePreviewMacroStub({
    required String outputDir,
    required String cCompilerPath,
    List<String> cCompilerArguments = const [],
  }) => previewCompiler.write(
    outputDir: outputDir,
    cCompilerPath: cCompilerPath,
    cCompilerArguments: cCompilerArguments,
  );

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
    if (linkerPath != null) ...hostPolicy.linkerPathArguments(linkerPath),
  ];
}
