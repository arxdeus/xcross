import 'dart:convert';
import 'dart:io';
import 'package:cli_kit/shared/process/process.dart';
import 'package:frontend_server_kit/shared/process/compiler_transport.dart';
import 'package:meta/meta.dart';

@internal
final class HostCompilerTransport implements CompilerTransport {
  HostCompilerTransport(this.process, this.runner);

  final Process process;
  final ProcessRunner runner;
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
      await runner.killTree(process).timeout(const Duration(seconds: 2));
    } finally {
      try {
        await process.stdin.close().timeout(const Duration(milliseconds: 200));
      } on Object {
        process.stdin.done.ignore();
      }
    }
  }
}
