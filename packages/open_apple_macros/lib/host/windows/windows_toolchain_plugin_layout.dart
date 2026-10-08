import 'package:open_apple_macros/host/shared/toolchain_plugin_layout.dart';
import 'package:path/path.dart' as p;

final class WindowsToolchainPluginLayout
    implements ToolchainPluginLayoutInterface {
  const WindowsToolchainPluginLayout();

  @override
  String pluginDirectory(p.Context paths, String runtimeResourcePath) =>
      paths.join(paths.dirname(paths.dirname(runtimeResourcePath)), 'bin');
}
