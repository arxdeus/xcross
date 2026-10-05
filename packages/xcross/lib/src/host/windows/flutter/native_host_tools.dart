import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:open_apple_macros/host/shared/toolchain_plugin_layout.dart';
import 'package:open_apple_macros/host/windows/windows_toolchain_plugin_layout.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';
import 'package:xcross/src/shared/flutter/errors.dart';

@internal
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
    if (!const ['arm64', 'x64'].contains(host.architecture)) {
      throw FlutterBuildError(
        'Unsupported Flutter host architecture: ${host.architecture}',
      );
    }
    return 'windows-${host.architecture}';
  }

  @override
  String get engineCacheDirectory => artifactPlatform;
  @override
  ToolchainPluginLayoutInterface get toolchainPluginLayout =>
      const WindowsToolchainPluginLayout();
  @override
  Future<HostCompiler> compiler(String clang) async =>
      (executable: clang, arguments: const <String>[]);
  @override
  Future<String> forwarder(String executable, String? launcher) async {
    if (_native(executable)) return executable;
    if (launcher != null &&
        _native(launcher) &&
        host.fileSystem.file(launcher).existsSync()) {
      return launcher;
    }
    final resolved = await runner.which('xcross.exe');
    if (resolved == null) throw missingNativeAssetToolForwarderError();
    return resolved;
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

@internal
FlutterBuildError missingNativeAssetToolForwarderError() => FlutterBuildError(
  "Windows native assets need the native xcross.exe binary: Flutter's "
  'native_toolchain_c only accepts a C compiler named clang.exe, so xcross '
  'installs copies of xcross.exe as clang.exe/cc.exe/ar.exe/ld.exe tool '
  'aliases. No xcross.exe was found (this happens when xcross runs through '
  '`dart run` or a `dart pub global` .bat launcher). Install the xcross '
  'release binary, add its directory to PATH, or set the xcross launcher path '
  'in `xcross config`.',
);
