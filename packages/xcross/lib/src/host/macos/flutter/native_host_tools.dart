import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';
import 'package:xcross/src/host/shared/flutter/posix_preview_macro_prologue.dart';
import 'package:xcross/src/shared/flutter/errors.dart';

@internal
final class MacOSNativeHostTools<T extends MacOSHostInterface>
    implements NativeHostTools<T> {
  MacOSNativeHostTools(this.host, this.runner) {
    if (!identical(host, runner.host)) {
      throw ArgumentError('Native host tools and runner must share one host');
    }
  }
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
    return 'darwin-${host.architecture}';
  }

  @override
  String get engineCacheDirectory => 'darwin-x64';
  @override
  String get previewMacroPrologue => posixPreviewMacroPrologue;
  @override
  Future<HostCompiler> compiler(String clang) async => (
    executable: '/usr/bin/xcrun',
    arguments: const ['--sdk', 'macosx', 'clang'],
  );
  @override
  Future<String> forwarder(String executable, String? launcher) async {
    return executable;
  }

  @override
  Future<void> link(String path, String target) async {
    await host.fileSystem.link(path).create(target);
  }
}
