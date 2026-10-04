import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_host_build_services.dart';
import 'package:xcross/src/shared/flutter/build/macho_dylib_rewriter.dart';

@internal
final class MacOSSwiftPmHostBuildServices<T extends PlatformHostInterface>
    extends PosixSwiftPmHostBuildServices<T> {
  MacOSSwiftPmHostBuildServices({
    required super.target,
    required super.filesystem,
    required super.sdkIdentity,
  });
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
