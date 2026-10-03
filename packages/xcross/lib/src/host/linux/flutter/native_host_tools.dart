import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';

final class LinuxNativeHostTools<T extends LinuxHostInterface>
    implements NativeHostTools<T> {
  LinuxNativeHostTools(this.host, this.runner);
  @override
  final T host;
  final ProcessRunner<T> runner;
  @override
  String get artifactPlatform {
    if (!const ['arm64', 'x64'].contains(host.architecture)) {
      throw FlutterBuildError(
        'Unsupported Flutter host architecture: ${host.architecture}',
      );
    }
    return 'linux-${host.architecture}';
  }

  @override
  String get engineCacheDirectory => artifactPlatform;
  @override
  Future<HostCompiler> compiler(String clang) async =>
      (executable: await runner.locateTool('cc'), arguments: const <String>[]);
  @override
  Future<String?> forwarder(String executable, String? launcher) async {
    return executable;
  }

  @override
  Future<void> link(String path, String target) async {
    await host.fileSystem.link(path).create(target);
  }
}
