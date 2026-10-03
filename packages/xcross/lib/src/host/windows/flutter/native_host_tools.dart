import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';

final class WindowsNativeHostTools<T extends WindowsHostInterface>
    implements NativeHostTools<T> {
  WindowsNativeHostTools(this.host, this.runner) {
    if (!identical(host, runner.host)) {
      throw ArgumentError('Native host tools and runner must share one host');
    }
  }
  @override
  final T host;
  final ProcessRunner<T> runner;
  @override
  String get artifactPlatform {
    if (!const ['x64'].contains(host.architecture)) {
      throw FlutterBuildError(
        'Unsupported Flutter host architecture: ${host.architecture}',
      );
    }
    return 'windows-${host.architecture}';
  }

  @override
  String get engineCacheDirectory => artifactPlatform;
  @override
  Future<HostCompiler> compiler(String clang) async =>
      (executable: clang, arguments: const <String>[]);
  @override
  Future<String?> forwarder(String executable, String? launcher) async {
    if (_native(executable)) return executable;
    if (launcher != null &&
        _native(launcher) &&
        host.fileSystem.file(launcher).existsSync()) {
      return launcher;
    }
    return runner.which('xcross.exe');
  }

  @override
  Future<void> link(String path, String target) async {
    final result = await runner.run(await runner.locateTool('cmd'), [
      '/c',
      'mklink',
      if (host.fileSystem.directory(target).existsSync()) '/J' else '/H',
      path,
      target,
    ]);
    if (result.exitCode != 0) {
      throw FileSystemException(result.stderr.trim(), path);
    }
  }

  bool _native(String path) =>
      p.windows.basename(path).toLowerCase() == 'xcross.exe';
}
