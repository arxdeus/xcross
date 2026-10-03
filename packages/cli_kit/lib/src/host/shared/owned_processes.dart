import 'dart:async';
import 'dart:io';

final class OwnedProcesses {
  final Set<Process> _processes = {};
  Future<Process> track(Future<Process> pending, ProcessStartMode mode) async {
    final process = await pending;
    if (mode == ProcessStartMode.normal ||
        mode == ProcessStartMode.inheritStdio) {
      _processes.add(process);
      unawaited(
        process.exitCode.then<void>(
          (_) {
            _processes.remove(process);
          },
          onError: (Object error) {
            _processes.remove(process);
          },
        ),
      );
    }
    return process;
  }

  bool contains(Process process) => _processes.contains(process);
}
