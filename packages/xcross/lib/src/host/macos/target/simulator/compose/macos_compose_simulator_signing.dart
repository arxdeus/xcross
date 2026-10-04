import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/compose_simulator_signing.dart';

final class MacOSComposeSimulatorSigning<T extends MacOSHostInterface>
    implements ComposeSimulatorSigning<T> {
  const MacOSComposeSimulatorSigning(this.runner);
  final ProcessRunner<T> runner;
  @override
  T get host => runner.host;
  @override
  Future<void> signBundle(String appPath) async {
    final frameworks = runner.host.fileSystem.directory(
      p.join(appPath, 'Frameworks'),
    );
    if (frameworks.existsSync()) {
      for (final framework in frameworks.listSync().whereType<Directory>()) {
        await _sign(framework.path);
      }
    }
    await _sign(appPath);
  }

  Future<void> _sign(String path) => runner.runTool('/usr/bin/codesign', [
    '--force',
    '--sign',
    '-',
    '--timestamp=none',
    path,
  ]);
}
