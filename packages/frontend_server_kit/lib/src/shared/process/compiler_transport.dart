abstract interface class CompilerProcessFactory {
  Future<CompilerTransport> start(String executable, List<String> arguments);
}

abstract interface class CompilerTransport {
  Stream<String> get output;
  Stream<String> get diagnostics;
  Future<int> get exitCode;
  Future<void> send(String command);
  Future<void> close();
}
