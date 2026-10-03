import 'package:cli_kit/cli_kit_shared.dart';

Log fixtureLog() => Log(output: FixtureLogOutput());

final class FixtureLogOutput implements LogOutput {
  @override
  bool get supportsAnsi => false;
  @override
  int get terminalColumns => 80;
  @override
  void stdout(String message) => print(message);
  @override
  void stderr(String message) => print(message);
  @override
  void write(String message) => print(message);
}

final class FixturePrivileges implements HostPrivilegesInterface {
  @override
  Future<void> ensureElevated({
    String? manualHint,
    String? deniedMessage,
  }) async => throw StateError('unexpected fixture elevation');
  @override
  Future<void> cacheCredentials({String? manualHint}) async =>
      throw StateError('unexpected fixture credentials');
  @override
  Future<String?> resolve() async => null;
}
