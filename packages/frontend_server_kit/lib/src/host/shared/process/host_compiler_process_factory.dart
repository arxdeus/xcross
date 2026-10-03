import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:frontend_server_kit/src/shared/process/compiler_transport.dart';

final class HostCompilerProcessFactory implements CompilerProcessFactory {
  const HostCompilerProcessFactory(this.processes);

  final HostProcessInterface processes;

  @override
  Future<CompilerTransport> start(
    String executable,
    List<String> arguments,
  ) async => _HostCompilerTransport(
    await processes.start(executable, arguments),
    processes,
  );
}

final class _HostCompilerTransport implements CompilerTransport {
  _HostCompilerTransport(this.process, this.processes);

  final Process process;
  final HostProcessInterface processes;
  Future<void>? _closing;

  @override
  Stream<String> get output =>
      process.stdout.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Stream<String> get diagnostics =>
      process.stderr.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Future<int> get exitCode => process.exitCode;

  @override
  Future<void> send(String command) async {
    process.stdin.write(command);
    await process.stdin.flush();
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      await send('quit\n').timeout(const Duration(milliseconds: 500));
      await exitCode.timeout(const Duration(milliseconds: 500));
    } on Object {
      await processes.killTree(process).timeout(const Duration(seconds: 2));
    } finally {
      try {
        await process.stdin.close().timeout(const Duration(milliseconds: 200));
      } on Object {
      process.stdin.done.ignore();
    }
    }
  }
}
