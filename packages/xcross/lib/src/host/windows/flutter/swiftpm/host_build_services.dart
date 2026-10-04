import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/macho_dylib_rewriter.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_build_services.dart';
import 'package:xcross/src/shared/flutter/swiftpm/librarian_resolver.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';

final class WindowsSwiftPmHostBuildServices<T extends PlatformHostInterface>
    implements SwiftPmHostBuildServices<T> {
  WindowsSwiftPmHostBuildServices({
    required this.target,
    required this.filesystem,
    required this.sdkIdentity,
    required this.runner,
    required this.sdkRepository,
    required this.toolchainResolver,
    required this.librarianResolver,
  }) {
    if (!identical(target.host, filesystem.host) ||
        !identical(target.host, runner.host) ||
        !identical(runner, toolchainResolver.runner) ||
        !identical(runner.host, sdkRepository.host) ||
        !identical(runner, librarianResolver.runner) ||
        !identical(filesystem, librarianResolver.filesystem)) {
      throw ArgumentError(
        'SwiftPM host services must share the configured target, runner and filesystem',
      );
    }
  }
  @override
  final IosTarget<T> target;
  @override
  final SwiftPmFilesystem<T> filesystem;
  @override
  final SwiftPmSdkIdentity sdkIdentity;
  final ProcessRunner<T> runner;
  final DarwinSdkRepository<T> sdkRepository;
  final DarwinToolchainResolver<T> toolchainResolver;
  final SwiftPmLibrarianResolver<T> librarianResolver;
  @override
  Future<void> stageFlutterFramework(
    String source,
    String destination, {
    bool? copy,
  }) =>
      filesystem.stageFlutterFramework(source, destination, copy: copy ?? true);
  @override
  Future<String?> cCompiler(String sysroot) =>
      toolchainResolver.resolveDarwinClang(sysroot);
  @override
  Future<String?> cxxCompiler(String sysroot) =>
      toolchainResolver.resolveDarwinClang(sysroot, name: 'clang++');
  @override
  Future<void> configureToolset(
    Map<String, Object> toolset,
    String linker,
    String? cc,
    String? cxx,
  ) async {
    for (final entry in {
      'cCompiler': ('clang', cc),
      'cxxCompiler': ('clang++', cxx),
    }.entries) {
      final path =
          entry.value.$2 ?? await librarianResolver.resolveTool(entry.value.$1);
      if (path == null) throw StateError('Could not find ${entry.value.$1}.');
      toolset[entry.key] = {
        'path': path.replaceAll(r'\', '/'),
        'extraCLIOptions': [r'-fdebug-prefix-map=C:\=/'],
      };
    }
    toolset['linker'] = {
      'path': filesystem.artifactFileSystem
          .file(linker)
          .resolveSymbolicLinksSync()
          .replaceAll(r'\', '/'),
    };
  }

  @override
  Future<Map<String, Object>> buildToolchainIdentity(DarwinSdk? sdk) async {
    if (sdk == null) {
      throw FlutterBuildError(
        'Darwin Swift SDK not found. Run `xcross sdk install <Xcode.xip>` first.',
      );
    }
    final sysroot = sdkRepository.iosSdk(sdk, target: target.buildPlatform);
    return sdkIdentity.swiftPmBuildToolchainIdentity(
      cCompilerPath: await toolchainResolver.resolveDarwinClang(sysroot),
      cxxCompilerPath: await toolchainResolver.resolveDarwinClang(
        sysroot,
        name: 'clang++',
      ),
      linkerPath: await toolchainResolver.resolveLd64Lld(),
      librarianPath: await librarianResolver.resolveLibrarian(),
    );
  }

  @override
  Future<void> rewriteDylib(String path, Set<String> names) async {
    final file = filesystem.artifactFileSystem.file(path);
    final bytes = await file.readAsBytes();
    if (MachODylibRewriter.rewriteBytes(
      bytes,
      dylibName: p.basename(path),
      producedDylibNames: names,
      source: path,
    )) {
      await file.writeAsBytes(bytes, flush: true);
    }
  }
}
