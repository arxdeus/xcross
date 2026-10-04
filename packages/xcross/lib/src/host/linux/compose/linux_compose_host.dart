import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/host/shared/compose/posix_compose_host.dart';
import 'package:xcross/src/shared/errors/errors.dart';

final class LinuxComposeHost<T extends LinuxHostInterface>
    extends PosixComposeHost<T> {
  LinuxComposeHost(super.host) {
    if (!isX64Architecture(host.architecture)) {
      throw XcrossError(
        'Compose on Linux ARM64 requires a Kotlin/Native Linux ARM64 host compiler and matching JNI/LLVM dependencies, which upstream does not publish. linuxArm64 is a compilation target, not a supported compiler host. Use a Linux x64 or macOS host.',
      );
    }
  }
  @override
  String get classifier => 'linux-x86_64';
  @override
  String get konanTarget => 'linux_x64';
  @override
  bool supportsJavaArchitecture(String architecture) =>
      isX64Architecture(architecture);
  @override
  List<String> installationArtifacts(String version) => [
    hostArtifact(version),
    'kotlin-native-prebuilt-$version-macos-x86_64.tar.gz',
  ];
}
