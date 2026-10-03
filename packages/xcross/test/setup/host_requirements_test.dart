import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/internal/linux_package_manager.dart';
import 'package:xcross/src/host/linux/setup/linux_setup_requirements.dart';
import 'package:xcross/src/host/macos/setup/macos_setup_requirements.dart';
import 'package:xcross/src/host/windows/setup/windows_setup_requirements.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';
import '../host_operations_fixtures.dart';

void main() {
  late Directory fixture;
  late _Privileges privileges;
  late ProcessRunner<LinuxHost> runner;
  late _Processes processes;
  late SetupRequirementServices services;
  late int pymdInstalls;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('host-requirements-');
    for (final tool in [
      'clang',
      'clang++',
      'ld64.lld',
      'swift',
      'flutter',
      'llvm-ar',
      'apt-get',
      'apt-cache',
      'brew',
      'pipx',
    ]) {
      File(p.join(fixture.path, tool)).createSync();
    }
    privileges = _Privileges();
    processes = _Processes();
    final host = LinuxHost(
      processes: processes,
      environment: {'PATH': fixture.path},
    );
    runner = ProcessRunner(
      host,
      log: fixtureLog(),
      stdinStream: const Stream.empty(),
    );
    pymdInstalls = 0;
    services = SetupRequirementServices(
      host: host,
      runner: runner,
      privileges: privileges,
      toolchain: DarwinToolchainResolver(runner, _Locations(fixture.path)),
      resolvePipx: () async => 'pipx',
      ensurePymdInstalled: () async {
        pymdInstalls++;
        return true;
      },
    );
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  test(
    'Linux installs through selected manager then verifies compilers and pipx',
    () async {
      await LinuxSetupRequirements(services).run();
      expect(privileges.cached, 1);
      expect(
        processes.commands.first,
        startsWith('/fixture/sudo apt-get install -y'),
      );
      expect(processes.commands.last, 'pipx ensurepath');
      expect(pymdInstalls, 1);
    },
  );

  test(
    'macOS drives Homebrew without Linux privilege or package operations',
    () async {
      await MacOSSetupRequirements(services).run();
      expect(processes.commands, ['brew install lld llvm', 'pipx ensurepath']);
      expect(privileges.cached, 0);
      expect(pymdInstalls, 1);
    },
  );

  test(
    'Windows only verifies manual tools and installs device helper',
    () async {
      await WindowsSetupRequirements(services).run();
      expect(processes.commands, isEmpty);
      expect(privileges.cached, 0);
      expect(pymdInstalls, 1);
    },
  );

  test(
    'missing Windows requirements reject before device installation',
    () async {
      File(p.join(fixture.path, 'flutter')).deleteSync();
      await expectLater(
        WindowsSetupRequirements(services).run(),
        throwsA(
          predicate(
            (Object error) =>
                error.toString().contains('Missing Windows requirements'),
          ),
        ),
      );
      expect(pymdInstalls, 0);
    },
  );

  test('missing Homebrew rejects without Linux fallback', () async {
    File(p.join(fixture.path, 'brew')).deleteSync();
    await expectLater(
      MacOSSetupRequirements(services).run(),
      throwsA(
        predicate(
          (Object error) => error.toString().contains('Homebrew is required'),
        ),
      ),
    );
    expect(processes.commands, isEmpty);
    expect(privileges.cached, 0);
  });
}

final class _Locations implements DarwinToolchainLocationsInterface {
  const _Locations(this.directory);
  final String directory;
  @override
  List<String> llvmToolDirectories() => [directory];
  @override
  String get clangInstallationHint => 'fixture clang';
  @override
  String get linkerInstallationHint => 'fixture linker';
}

final class _Processes implements HostProcessInterface {
  final commands = <String>[];
  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    final isVersion = arguments.contains('--version');
    final isIndex = executable.contains('apt-cache');
    if (!isVersion && !isIndex) {
      commands.add('$executable ${arguments.join(' ')}');
    }
    return _Child(
      isIndex
          ? LinuxPackageManager.apt.packages.join('\n')
          : executable.contains('ld64.lld')
          ? 'LLD 22.1.0'
          : 'clang version 22.1.0',
    );
  }

  @override
  Future<String?> findOnShellPath(
    String name, {
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async => null;
  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) async {}
}

final class _Child implements Process {
  _Child(this.output);
  final String output;
  @override
  int get pid => 1;
  @override
  Future<int> get exitCode async => 0;
  @override
  Stream<List<int>> get stdout => Stream.value(utf8.encode(output));
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  IOSink get stdin => _Input();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Input implements IOSink {
  @override
  Future<void> get done async {}
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Privileges implements HostPrivilegesInterface {
  int cached = 0;
  @override
  Future<void> cacheCredentials({String? manualHint}) async {
    cached++;
  }

  @override
  Future<String?> resolve() async => '/fixture/sudo';
  @override
  Future<void> ensureElevated({
    String? manualHint,
    String? deniedMessage,
  }) async => throw StateError('unexpected elevation');
}
