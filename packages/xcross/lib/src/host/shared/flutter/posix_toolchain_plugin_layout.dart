import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/open_apple_macros.dart';

/// Linux and macOS toolchains keep host macro plugins under the resource
/// directory: `<prefix>/usr/lib/swift/host/plugins`.
@internal
final class PosixToolchainPluginLayout
    implements ToolchainPluginLayoutInterface {
  const PosixToolchainPluginLayout();

  @override
  String pluginDirectory(p.Context paths, String runtimeResourcePath) =>
      paths.join(runtimeResourcePath, 'host', 'plugins');
}
