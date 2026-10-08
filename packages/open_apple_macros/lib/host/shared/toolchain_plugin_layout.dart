import 'package:path/path.dart' as p;

abstract interface class ToolchainPluginLayoutInterface {
  String pluginDirectory(p.Context paths, String runtimeResourcePath);
}
