import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/errors.dart';

enum ComposeHostOs { linux, macos, windows }

final class ComposeHost {
  const ComposeHost._(
    this.os,
    this.classifier,
    this.archiveExtension,
    this.konanTarget,
  );

  static const linuxX64 = ComposeHost._(
    ComposeHostOs.linux,
    'linux-x86_64',
    'tar.gz',
    'linux_x64',
  );
  static const windowsX64 = ComposeHost._(
    ComposeHostOs.windows,
    'windows-x86_64',
    'zip',
    'mingw_x64',
  );
  static const macosX64 = ComposeHost._(
    ComposeHostOs.macos,
    'macos-x86_64',
    'tar.gz',
    'macos_x64',
  );
  static const macosArm64 = ComposeHost._(
    ComposeHostOs.macos,
    'macos-aarch64',
    'tar.gz',
    'macos_arm64',
  );

  final ComposeHostOs os;
  final String classifier;
  final String archiveExtension;
  final String konanTarget;

  bool get isWindows => os == ComposeHostOs.windows;
  bool get isMacOS => os == ComposeHostOs.macos;

  bool supportsJavaArchitecture(String architecture) => this == macosArm64
      ? _isArm64(architecture.trim().toLowerCase())
      : _isX64(architecture.trim().toLowerCase());

  String hostArtifact(String version) =>
      'kotlin-native-prebuilt-$version-$classifier.$archiveExtension';

  static String macosX64OverlayArtifact(String version) =>
      'kotlin-native-prebuilt-$version-macos-x86_64.tar.gz';

  String konancExecutable(String kotlinHome) =>
      p.join(kotlinHome, 'bin', isWindows ? 'konanc.bat' : 'konanc');

  String javaExecutable(String javaHome) =>
      p.join(javaHome, 'bin', isWindows ? 'java.exe' : 'java');

  List<String> invokeExecutable(String executable, List<String> arguments) =>
      isWindows && p.extension(executable).toLowerCase() == '.bat'
      ? ['cmd.exe', '/d', '/c', executable, ...arguments]
      : [executable, ...arguments];

  static ComposeHost current({String? operatingSystem, String? architecture}) {
    final os = operatingSystem ?? Platform.operatingSystem;
    final arch = (architecture ?? _hostArchitecture()).trim().toLowerCase();
    if (os == 'linux' && _isX64(arch)) return linuxX64;
    if (os == 'windows' && _isX64(arch)) return windowsX64;
    if (os == 'macos' && _isX64(arch)) return macosX64;
    if (os == 'macos' && _isArm64(arch)) return macosArm64;
    if (os == 'linux' && _isArm64(arch)) {
      throw XcrossError(
        'Compose on Linux ARM64 requires a Kotlin/Native Linux ARM64 host '
        'compiler and matching JNI/LLVM dependencies, which upstream does '
        'not publish. linuxArm64 is a compilation target, not a supported '
        'compiler host. Use a Linux x64 or macOS host.',
      );
    }
    throw XcrossError(
      'Compose Kotlin/Native toolchain supports Linux x64, macOS x64/ARM64, '
      'and Windows x64 only; '
      '$os $arch is not supported.',
    );
  }

  static bool _isX64(String architecture) =>
      architecture == 'x64' ||
      architecture == 'x86_64' ||
      architecture == 'amd64';

  static bool _isArm64(String architecture) =>
      architecture == 'arm64' || architecture == 'aarch64';

  static String _hostArchitecture() => Abi.current().toString().split('_').last;
}
