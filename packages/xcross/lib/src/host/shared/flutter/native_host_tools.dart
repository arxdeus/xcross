import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:open_apple_macros/host/shared/toolchain_plugin_layout.dart';

@internal
typedef HostCompiler = ({String executable, List<String> arguments});

@internal
abstract interface class NativeHostTools<T extends PlatformHostInterface> {
  T get host;
  String get artifactPlatform;
  String get engineCacheDirectory;
  ToolchainPluginLayoutInterface get toolchainPluginLayout;
  Future<HostCompiler> compiler(String clang);
  Future<String> forwarder(String executable, String? launcher);
  Future<void> link(String path, String target);
}
