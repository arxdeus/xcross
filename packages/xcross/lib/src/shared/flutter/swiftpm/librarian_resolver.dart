import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';

@internal
abstract interface class SwiftPmLlvmToolLookup<
  T extends PlatformHostInterface
> {
  ProcessRunner<T> get runner;
  Future<String?> locate(String name);
}

@internal
final class DarwinSwiftPmLlvmToolLookup<T extends PlatformHostInterface>
    implements SwiftPmLlvmToolLookup<T> {
  DarwinSwiftPmLlvmToolLookup(this.resolver);
  final DarwinToolchainResolver<T> resolver;
  @override
  ProcessRunner<T> get runner => resolver.runner;
  @override
  Future<String?> locate(String name) => resolver.locateLlvmTool(name);
}

@internal
final class SwiftPmLibrarianResolver<T extends PlatformHostInterface> {
  SwiftPmLibrarianResolver({
    required this.runner,
    required this.filesystem,
    required this.lookup,
  }) {
    if (!identical(runner, lookup.runner) ||
        !identical(runner.host, filesystem.host)) {
      throw ArgumentError(
        'SwiftPM librarian ports must share the configured runner and host',
      );
    }
  }
  final ProcessRunner<T> runner;
  final SwiftPmFilesystem<T> filesystem;
  final SwiftPmLlvmToolLookup<T> lookup;
  static const libtool = 'llvm-libtool-darwin';
  static const librarians = [libtool, 'llvm-ar'];
  Future<String?> resolveTool(String name) async {
    final path = await lookup.locate(runner.hostExecutableName(name));
    return path == null
        ? null
        : SwiftPmFilesystem.jsonPath(
            filesystem.artifactFileSystem.file(path).resolveSymbolicLinksSync(),
          );
  }

  Future<String> resolveLibrarian() async {
    final libtoolPath = await resolveTool(libtool);
    if (libtoolPath != null) return libtoolPath;
    final archiver = await resolveTool('llvm-ar');
    if (archiver != null) {
      final sibling = p.join(
        p.dirname(archiver),
        runner.hostExecutableName(libtool),
      );
      return filesystem.artifactFileSystem.file(sibling).existsSync()
          ? SwiftPmFilesystem.jsonPath(sibling)
          : archiver;
    }
    throw FlutterBuildError(
      'No Darwin-capable archiver found (${librarians.join(' or ')}). Install LLVM and retry.',
    );
  }
}
