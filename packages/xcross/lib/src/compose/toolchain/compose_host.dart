import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/errors.dart';

enum ComposeHostOs { linux, windows }

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

  final ComposeHostOs os;
  final String classifier;
  final String archiveExtension;
  final String konanTarget;

  bool get isWindows => os == ComposeHostOs.windows;

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
    final arch = architecture ?? _hostArchitecture();
    if (os == 'linux' && _isX64(arch)) return linuxX64;
    if (os == 'windows' && _isX64(arch)) return windowsX64;
    throw XcrossError(
      'Compose Kotlin/Native toolchain supports Linux x64 and Windows x64 only; '
      '$os $arch is not supported.',
    );
  }

  static bool _isX64(String architecture) =>
      architecture == 'x64' ||
      architecture == 'x86_64' ||
      architecture == 'amd64';

  static String _hostArchitecture() {
    final env = Platform.environment;
    final explicit = env['PROCESSOR_ARCHITECTURE'] ?? env['HOSTTYPE'];
    if (explicit != null && explicit.isNotEmpty) return explicit.toLowerCase();
    return Platform.version.toLowerCase().contains('arm64') ? 'arm64' : 'x64';
  }
}
