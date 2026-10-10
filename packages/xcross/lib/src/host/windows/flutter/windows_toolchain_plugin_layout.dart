import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/open_apple_macros.dart';

/// Windows toolchains ship host macro plugins as DLLs beside the compiler,
/// in `<toolchain>\usr\bin`.
@internal
final class WindowsToolchainPluginLayout
    implements ToolchainPluginLayoutInterface {
  const WindowsToolchainPluginLayout();

  @override
  String pluginDirectory(p.Context paths, String runtimeResourcePath) =>
      paths.join(paths.dirname(paths.dirname(runtimeResourcePath)), 'bin');
}
