import 'package:args/command_runner.dart';
import 'package:xcross_dap/xcross_dap.dart';

/// `xcross flutter dap` — Debug Adapter Protocol server driving
/// `xcross flutter run`.
///
/// Spawned by `.vscode/xcross_dap.dart` (see `xcross ide vscode`) or by an
/// LSP4IJ DAP run config (see `xcross ide idea`). Launch configs must set
/// `"xcross": true`; other Flutter sessions are proxied to Flutter's DAP.
final class DapCommand extends Command<void> {
  @override
  String get name => 'dap';

  @override
  String get description =>
      'Debug Adapter Protocol server for IDE Run & Debug buttons.';

  @override
  bool get hidden => true;

  @override
  Future<void> run() => DapSession.run(startXcross: XcrossDap.new);
}
