import 'package:args/command_runner.dart';
import 'package:xcross/src/dap/dap.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';

/// `xcross flutter dap` — Debug Adapter Protocol server driving
/// `xcross flutter run`.
///
/// Spawned by `.vscode/xcross_dap.dart` (see `xcross ide vscode`) or by an
/// LSP4IJ DAP run config (see `xcross ide idea`). Launch configs must set
/// `"env": {"XCROSS": "true"}`; other Flutter sessions are proxied to
/// Flutter's DAP.
final class DapCommand extends Command<void> {
  DapCommand(this.runtime) {
    argParser.addFlag('test', negatable: false);
  }

  final XcrossRuntime runtime;
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
      localHttp: runtime.localHttp,
      runner: runtime.runner,
      launcher: runtime.executable,
    ),
  );
}
