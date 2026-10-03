import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/shared/update/update_host_policy.dart';
import 'package:xcross/src/update/install_layout.dart';

final class WindowsUpdatePolicy implements UpdateHostPolicy {
  const WindowsUpdatePolicy(this.host, this.privileges);
  final WindowsHostInterface host;
  final HostPrivilegesInterface privileges;

  @override
  String releaseAsset() {
    if (host.architecture == 'x64') return 'xcross-windows-x64.zip';
    throw XcrossError(
      'no prebuilt xcross release for windows/${host.architecture}; build from source instead',
    );
  }

  @override
  Future<FileSwapOperations> prepare(InstallLayout layout) async {
    if (!layout.isWritable) {
      await privileges.ensureElevated(
        deniedMessage:
            'Updating xcross in ${layout.binDir} requires Administrator.\nOpen PowerShell with "Run as administrator" and retry.',
      );
      if (!layout.isWritable) {
        throw XcrossError(
          'The installation directory is not writable: ${layout.binDir}',
        );
      }
    }
    return WindowsFileSwapOperations(host);
  }
}

final class WindowsFileSwapOperations implements FileSwapOperations {
  const WindowsFileSwapOperations(this.host);
  final PlatformHostInterface host;

  @override
  Future<void> copy(String source, String target) async {
    await host.fileSystem.file(source).copy(host.paths.ioPath(target));
  }

  @override
  Future<void> move(String source, String target) async {
    await host.fileSystem.file(source).rename(host.paths.ioPath(target));
  }

  @override
  Future<void> delete(String path) async {
    await host.fileSystem.file(path).delete();
  }
}
