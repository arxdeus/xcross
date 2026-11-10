import 'dart:io';

import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:meta/meta.dart';
import 'package:test/test.dart';
import 'package:xcross/src/host/macos/target/simulator/compose/macos_compose_simulator_signing.dart';

import '../host_operations_fixtures.dart';

@internal
final class RecordingProcesses implements HostProcessInterface {
  final calls = <List<String>>[];

  @override
  ProcessExitDiagnostic describeExit(int exitCode) =>
      const ProcessExitDiagnostic(crashed: false, description: null);

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    calls.add([executable, ...arguments]);
    return Process.start('/usr/bin/true', const []);
  }

  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) async {}

  @override
  Future<String?> findOnShellPath(
    String name, {
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async => null;
}

void main() {
  test(
    testOn: 'mac-os || linux',
    'signs every framework and loose Swift dylib before the app',
    () async {
      final tmp = Directory.systemTemp.createTempSync('sim_sign_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final app = '${tmp.path}/App.app';
      Directory('$app/Frameworks/Pkg.framework').createSync(recursive: true);
      File(
        '$app/Frameworks/libswiftCompatibilitySpan.dylib',
      ).writeAsStringSync('');
      File('$app/Frameworks/README').writeAsStringSync('');
      final processes = RecordingProcesses();
      final host = MacOSHost(
        architecture: 'arm64',
        temporaryDirectory: tmp.path,
        processes: processes,
      );
      await MacOSComposeSimulatorSigning(
        fixtureRunner(host, log: fixtureLog()),
      ).signBundle(app);
      expect(processes.calls.map((call) => call.last), [
        '$app/Frameworks/Pkg.framework',
        '$app/Frameworks/libswiftCompatibilitySpan.dylib',
        app,
      ]);
      expect(processes.calls.first.first, '/usr/bin/codesign');
    },
  );
}
