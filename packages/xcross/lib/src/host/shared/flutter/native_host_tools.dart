import 'package:cli_kit/cli_kit_shared.dart';

typedef HostCompiler = ({String executable, List<String> arguments});

abstract interface class NativeHostTools<T extends PlatformHostInterface> {
  T get host;
  String get artifactPlatform;
  String get engineCacheDirectory;
  Future<HostCompiler> compiler(String clang);
  Future<String?> forwarder(String executable, String? launcher);
  Future<void> link(String path, String target);
}
