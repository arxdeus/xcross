import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/swiftpm/open_apple_macros.dart';

@internal
typedef HostCompiler = ({String executable, List<String> arguments});

/// The host-native tools Apple tool shims and SwiftPM builds need: the host
/// C compiler, the native-tool forwarder and the toolchain plugin layout.
@internal
abstract interface class AppleHostTools<T extends PlatformHostInterface> {
  T get host;
  ToolchainPluginLayoutInterface get toolchainPluginLayout;
  Future<HostCompiler> compiler(String clang);
  Future<String> forwarder(String executable, String? launcher);
}
