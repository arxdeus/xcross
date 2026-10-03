import 'dart:async';
import 'dart:convert';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmToolchain<T extends PlatformHostInterface> {
  SwiftPmToolchain({required this.filesystem,required this.hostPolicy,required this.runner,required this.sdkIdentity,required this.sdkRepository,required this.target,required this.toolchainResolver});
  final SwiftPmFilesystem<T> filesystem;
  final SwiftPmHostPolicy hostPolicy;
  final ProcessRunner<T> runner;
  final SwiftPmSdkIdentity sdkIdentity;
  final DarwinSdkRepository<T> sdkRepository;
  final IosTarget<T> target;
  final DarwinToolchainResolver<T> toolchainResolver;

  static const libtool = 'llvm-libtool-darwin';
  static const librarians = [libtool, 'llvm-ar'];

  Future<Map<String, Object>> resolveBuildToolchainIdentity(
    DarwinSdk sdk,
  ) async => sdkIdentity.swiftPmBuildToolchainIdentity(
    cCompilerPath: await toolchainResolver.resolveDarwinClang(
      sdkRepository.iosSdk(sdk, target: target.buildPlatform),
    ),
    cxxCompilerPath: await toolchainResolver.resolveDarwinClang(
      sdkRepository.iosSdk(sdk, target: target.buildPlatform),
      name: 'clang++',
    ),
    linkerPath: await toolchainResolver.resolveLd64Lld(),
    librarianPath: await resolveLibrarian(),
  );

  /// Writes SwiftPM's external toolset and returns its path.
  ///
  /// Every host needs the `librarian` entry: SwiftPM validates the toolchain
  /// against the *target* triple before building, and for an Apple triple that
  /// means Apple's `libtool` ("toolchain is invalid: could not find CLI tool
  /// `libtool`"), which no cross host has. Windows overrides the compilers and
  /// the linker on top; Linux passes its linker as a `swift build` flag
  /// instead.
  Future<String> writeToolset({
    required String outputDir,
    required String linkerPath,
    String? cCompilerPath,
    String? cxxCompilerPath,
    Future<String?> Function(String name)? locateTool,
    String? librarianPath,
  }) async {
    final output = filesystem.artifactFileSystem.directory(outputDir);
    await output.create(recursive: true);
    // LLVM often never registers itself on PATH, so reach into its install
    // directories too (see [DarwinSdk.llvmToolDirs]).
    final locate = locateTool ?? toolchainResolver.locateLlvmTool;
    final toolset = <String, Object>{
      'schemaVersion': '1.0',
      'rootPath': SwiftPmFilesystem.jsonPath(output.resolveSymbolicLinksSync()),
    };

    Future<String?> resolve(String name) async {
      final path = await locate(runner.hostExecutableName(name));
      return path == null
          ? null
          : SwiftPmFilesystem.jsonPath(filesystem.artifactFileSystem.file(path).resolveSymbolicLinksSync());
    }

    final librarian =
        librarianPath ?? await resolveLibrarian(locateTool: locateTool);
    toolset['librarian'] = {'path': librarian};

    await hostPolicy.configureToolset(
      toolset,
      linkerPath,
      cCompilerPath,
      cxxCompilerPath,
      resolve,
    );
    final toolsetPath = p.join(outputDir, 'xcross-toolset.json');
    await filesystem.writeStable(
      toolsetPath,
      '${const JsonEncoder.withIndent('  ').convert(toolset)}\n',
    );
    return toolsetPath;
  }

  /// Picks the archiver for an Apple target: `llvm-libtool-darwin` when it is
  /// on PATH, else the copy sitting next to `llvm-ar` inside LLVM's own bin
  /// directory (Debian and Ubuntu only symlink a subset of LLVM into
  /// `/usr/bin`), else `llvm-ar` itself.
  Future<String> resolveLibrarian({
    Future<String?> Function(String name)? locateTool,
  }) async {
    final locate = locateTool ?? toolchainResolver.locateLlvmTool;
    Future<String?> resolve(String name) async {
      final path = await locate(runner.hostExecutableName(name));
      return path == null
          ? null
          : SwiftPmFilesystem.jsonPath(filesystem.artifactFileSystem.file(path).resolveSymbolicLinksSync());
    }

    final librarian = await resolveLibrarianInternal(resolve);
    if (librarian != null) return librarian;
    throw FlutterBuildError(
      'No Darwin-capable archiver found (${SwiftPmToolchain.librarians.join(' or ')}). '
      'Install LLVM and retry.',
    );
  }

  Future<String?> resolveLibrarianInternal(
    Future<String?> Function(String name) resolve,
  ) async {
    final libtool = await resolve(SwiftPmToolchain.libtool);
    if (libtool != null) return libtool;
    final archiver = await resolve('llvm-ar');
    if (archiver == null) return null;
    final sibling = p.join(
      p.dirname(archiver),
      runner.hostExecutableName(SwiftPmToolchain.libtool),
    );
    return filesystem.artifactFileSystem.file(sibling).existsSync()
        ? SwiftPmFilesystem.jsonPath(sibling)
        : archiver;
  }
}
