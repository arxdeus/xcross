import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/host/shared/compose/posix_compose_host.dart';
import 'package:xcross/src/shared/errors/errors.dart';

final class MacOSComposeHost<T extends MacOSHostInterface>
    extends PosixComposeHost<T> {
  MacOSComposeHost(super.host) {
    if (!isX64Architecture(host.architecture) &&
        !isArm64Architecture(host.architecture)) {
      throw XcrossError(
        'Unsupported macOS Kotlin/Native compiler architecture: ${host.architecture}.',
      );
    }
  }
  @override
  String get classifier =>
      isArm64Architecture(host.architecture) ? 'macos-aarch64' : 'macos-x86_64';
  @override
  String get konanTarget =>
      isArm64Architecture(host.architecture) ? 'macos_arm64' : 'macos_x64';
  @override
  bool supportsJavaArchitecture(String architecture) =>
      isArm64Architecture(host.architecture)
      ? isArm64Architecture(architecture)
      : isX64Architecture(architecture);
  @override
  List<String> installationArtifacts(String version) => [hostArtifact(version)];
  @override
  String resolveAppleTool(
    String directory,
    String name,
    Iterable<String> searchPath, {
    String? nativeFallback,
  }) {
    final resolved = siblingOrOnPath(
      directory,
      name,
      searchPath,
      host.fileSystem,
    );
    if (nativeFallback == null || host.fileSystem.file(resolved).existsSync()) {
      return resolved;
    }
    final native = siblingOrOnPath(
      directory,
      nativeFallback,
      searchPath,
      host.fileSystem,
    );
    return host.fileSystem.file(native).existsSync() ? native : resolved;
  }
}
