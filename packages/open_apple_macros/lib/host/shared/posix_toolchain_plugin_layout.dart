import 'package:open_apple_macros/host/shared/toolchain_plugin_layout.dart';
import 'package:path/path.dart' as p;

final class PosixToolchainPluginLayout
    implements ToolchainPluginLayoutInterface {
  const PosixToolchainPluginLayout();

  @override
  String pluginDirectory(p.Context paths, String runtimeResourcePath) =>
      paths.join(runtimeResourcePath, 'host', 'plugins');
}
