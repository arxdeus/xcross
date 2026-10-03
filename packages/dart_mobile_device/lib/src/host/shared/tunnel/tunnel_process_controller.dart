import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';

final class TunnelProcessController {
  TunnelProcessController(this.runner);

  final ProcessRunner runner;
  Process? _process;
  Future<void>? _stopping;

  bool get ownsProcess => _process != null;

  Future<void> start(
    List<String> argv, {
    required String logPath,
    required Map<String, String> environment,
  }) async {
    if (_process != null) throw StateError('tunnel process already running');
    await _stopping;
    final log = runner.host.fileSystem.file(logPath);
    await log.parent.create(recursive: true);
    final process = await runner.start(
      argv.first,
      argv.sublist(1),
      environment: environment,
    );
    _process = process;
    try {
      await process.stdin.close();
    } on Object {
      process.stdin.done.ignore();
    }
    final sink = log.openWrite(mode: FileMode.append);
    final output = process.stdout.listen(sink.add, onError: (Object _) {});
    final diagnostics = process.stderr.listen(sink.add, onError: (Object _) {});
    unawaited(
      process.exitCode.then((_) async {
        if (identical(_process, process)) _process = null;
        await output.cancel();
        await diagnostics.cancel();
        await sink.close();
      }),
    );
  }

  Future<void> stop() =>
      _stopping ??= _stop().whenComplete(() => _stopping = null);

  Future<void> _stop() async {
    final process = _process;
    _process = null;
    if (process == null) return;
    await runner.killTree(process);
  }
}
