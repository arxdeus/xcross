import 'package:args/command_runner.dart';
import 'package:dart_mobile_device/dart_mobile_device_shared.dart'
    show TunnelAvailability;
import 'package:frontend_server_kit/frontend_server_kit.dart'
    show PackageUriLoader;
import 'package:xcross/src/shared/dap/dap.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';

/// `xcross flutter dap` — Debug Adapter Protocol server driving
/// `xcross flutter run`.
///
/// Spawned by `.vscode/xcross_dap.dart` (see `xcross ide vscode`) or by an
/// LSP4IJ DAP run config (see `xcross ide idea`). Launch configs must set
/// `"env": {"XCROSS": "true"}`; other Flutter sessions are proxied to
/// Flutter's DAP.
final class DapCommand extends Command<void> {
  DapCommand(this.runtime, {required this.tunnelAvailability}) {
    argParser.addFlag('test', negatable: false);
  }

  final XcrossRuntime runtime;
  final TunnelAvailability tunnelAvailability;
  @override
  String get name => 'dap';

  @override
  String get description =>
      'Debug Adapter Protocol server for IDE Run & Debug buttons.';

  @override
  bool get hidden => true;

  @override
  Future<void> run() => DapSession.run(
    runner: runtime.runner,
    input: runtime.input,
    output: runtime.output,
    errors: runtime.errors,
    testAdapter: argResults!.flag('test'),
    flutterAdapterArguments: argResults!.rest,
    flutterRoot: runtime.config.roots?.flutterSdk,
    environmentRoot:
        runtime.config.config?.environment['FLUTTER_ROOT'] as String?,
    flutterTool: runtime.config.tool('flutter'),
    declarative: runtime.config.isConfigured,
    startXcross: (channel) => XcrossDap(
      channel,
      packageUriLoader: PackageUriLoader(
        fileSystem: runtime.runner.host.fileSystem,
        paths: runtime.runner.host.paths.context,
      ),
      tunnelAvailability: tunnelAvailability,
      runner: runtime.runner,
      launcher: runtime.executable,
    ),
  );
}
