import 'dart:async';
import 'dart:convert';
import 'dart:io';

final class DapChildController {
  DapChildController({
    required this.cleanup,
    this.quitTimeout = const Duration(seconds: 5),
  });
  final Future<void> Function(Process) cleanup;
  final Duration quitTimeout;
  Process? _child;
  Future<void>? _closing;

  Future<void> attach(Process child) async {
    if (_closing != null) {
      await cleanup(child);
      throw StateError('DAP child startup cancelled');
    }
    if (_child != null) throw StateError('DAP child already owned');
    _child = child;
  }

  void writeKey(String key) {
    try {
      _child?.stdin.add(utf8.encode(key));
    } on Object catch (_) {}
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    final child = _child;
    if (child == null) return;
    writeKey('q');
    _child = null;
    final exited = await child.exitCode
        .then((_) => true)
        .timeout(quitTimeout, onTimeout: () => false);
    if (!exited) await cleanup(child);
  }
}
