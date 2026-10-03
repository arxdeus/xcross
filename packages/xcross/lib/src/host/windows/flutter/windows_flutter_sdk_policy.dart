import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/host/shared/flutter/flutter_sdk_host_policy.dart';

final class WindowsFlutterSdkPolicy<T extends WindowsHostInterface>
    implements FlutterSdkHostPolicy<T> {
  @override
  Future<String> rootFromExecutable(
    String executable,
    ProcessRunner<T> runner,
  ) async {
    final p = runner.host.paths.context;
    if (p.basename(p.dirname(executable)) == 'shims') {
      final result = await runner.run(await runner.locateTool('mise'), [
        'where',
        'flutter',
      ]);
      if (result.exitCode == 0) {
        final root = result.stdout.trim();
        if (runner.host.fileSystem
            .directory(p.join(root, 'bin'))
            .existsSync()) {
          return root;
        }
      }
    }
    return p.dirname(p.dirname(executable));
  }
}
