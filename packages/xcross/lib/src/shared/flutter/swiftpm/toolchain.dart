import 'dart:convert';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_build_services.dart';
import 'package:xcross/src/shared/flutter/swiftpm/librarian_resolver.dart';

final class SwiftPmToolchain<T extends PlatformHostInterface> {
  SwiftPmToolchain({
    required this.filesystem,
    required this.hostBuildServices,
    required this.librarianResolver,
  });
  final SwiftPmFilesystem<T> filesystem;
  final SwiftPmHostBuildServices<T> hostBuildServices;
  final SwiftPmLibrarianResolver<T> librarianResolver;
  static const libtool = SwiftPmLibrarianResolver.libtool;
  static const librarians = SwiftPmLibrarianResolver.librarians;
  Future<Map<String, Object>> resolveBuildToolchainIdentity(DarwinSdk? sdk) =>
      hostBuildServices.buildToolchainIdentity(sdk);
  Future<String> writeToolset({
    required String outputDir,
    required String linkerPath,
    String? cCompilerPath,
    String? cxxCompilerPath,
    String? librarianPath,
  }) async {
    final output = filesystem.artifactFileSystem.directory(outputDir);
    await output.create(recursive: true);
    final toolset = <String, Object>{
      'schemaVersion': '1.0',
      'rootPath': SwiftPmFilesystem.jsonPath(output.resolveSymbolicLinksSync()),
      'librarian': {
        'path': librarianPath ?? await librarianResolver.resolveLibrarian(),
      },
    };
    await hostBuildServices.configureToolset(
      toolset,
      linkerPath,
      cCompilerPath,
      cxxCompilerPath,
    );
    final path = p.join(outputDir, 'xcross-toolset.json');
    await filesystem.writeStable(
      path,
      '${const JsonEncoder.withIndent('  ').convert(toolset)}\n',
    );
    return path;
  }
}
