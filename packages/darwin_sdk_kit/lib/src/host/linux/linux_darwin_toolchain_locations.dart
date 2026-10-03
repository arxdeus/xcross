import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/src/host/shared/darwin_toolchain_locations.dart';

final class LinuxDarwinToolchainLocations
    implements DarwinToolchainLocationsInterface {
  const LinuxDarwinToolchainLocations(this.host);
  final LinuxHostInterface host;
  @override
  List<String> llvmToolDirectories() {
    final directory = host.fileSystem.directory('/usr/lib');
    if (!directory.existsSync()) return const [];
    final names =
        directory
            .listSync()
            .map((entry) => host.paths.context.basename(entry.path))
            .where((name) => name.startsWith('llvm-'))
            .toList()
          ..sort(
            (a, b) => (int.tryParse(b.substring(5).split('.').first) ?? -1)
                .compareTo(int.tryParse(a.substring(5).split('.').first) ?? -1),
          );
    return [
      for (final name in names)
        host.paths.context.join('/usr/lib', name, 'bin'),
    ];
  }

  @override
  String get linkerInstallationHint =>
      'Install LLVM lld 19 or newer with `xcross setup`, or your LLVM package manager, and put ld64.lld on PATH.';
  @override
  String get clangInstallationHint =>
      'Install LLVM with `xcross setup`, or `sudo apt install clang`, and put clang on PATH.';
}
