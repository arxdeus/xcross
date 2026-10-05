import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/host/windows/windows_paths.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/windows/sdk/windows_swift_environment.dart';
import 'package:xcross/src/shared/cli/basic/doctor_models.dart';
import 'package:xcross/src/shared/errors/errors.dart';

import '../log_fixture.dart';

const _swiftRoot = r'C:\Users\Mind\AppData\Local\Programs\Swift';
const _userSdk =
    r'C:\Users\Mind\AppData\Local\Programs\Swift\Platforms\6.4.0'
    r'\Windows.platform\Developer\SDKs\Windows.sdk';
const _machineSdk = r'C:\Swift\Platforms\6.4.0\Windows.sdk';
const _environmentSdk = r'C:\Selected\Windows.sdk';
const _userKey = r'HKCU\Environment';
const _machineKey =
    r'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment';

void main() {
  late WindowsSdkRootFixture fixture;
  setUp(() => fixture = WindowsSdkRootFixture(TestLogOutput()));
  tearDown(() => fixture.dispose());

  test('uses the User registry value when SDKROOT is absent', () async {
    fixture
      ..sdk(_userSdk)
      ..registry[_userKey] = '$_userSdk\\';
    final environment = fixture.environment();
    expect(await environment.swiftEnvironment(), {'SDKROOT': '$_userSdk\\'});
    final check = (await environment.doctorChecks()).single;
    expect(check.status, DoctorStatus.success);
    expect(check.name, 'SDKROOT');
    expect(check.message, contains('User environment in the registry'));
    expect(check.path, '$_userSdk\\');
    expect(fixture.processes.queries, [_userKey]);
    expect(
      fixture.processes.executables.single,
      r'C:\WINDOWS\System32\reg.exe',
    );
  });

  test('falls back to the Machine registry value', () async {
    fixture
      ..sdk(_machineSdk)
      ..registry[_machineKey] = _machineSdk;
    final environment = fixture.environment(variables: {'SDKROOT': ''});
    expect(await environment.swiftEnvironment(), {'SDKROOT': _machineSdk});
    final check = (await environment.doctorChecks()).single;
    expect(check.status, DoctorStatus.success);
    expect(check.message, contains('Machine environment in the registry'));
    expect(fixture.processes.queries, [_userKey, _machineKey]);
  });

  test('expands registry values that reference other variables', () async {
    fixture
      ..sdk(_userSdk)
      ..registry[_userKey] =
          r'%LOCALAPPDATA%\Programs\Swift\Platforms\6.4.0'
          r'\Windows.platform\Developer\SDKs\Windows.sdk';
    expect(await fixture.environment().swiftEnvironment(), {
      'SDKROOT': _userSdk,
    });
  });

  test('derives the SDK beside the located Swift toolchain', () async {
    fixture
      ..sdk(_userSdk)
      ..sdk(
        r'C:\Users\Mind\AppData\Local\Programs\Swift\Platforms\6.3.0'
        r'\Windows.platform\Developer\SDKs\Windows.sdk',
      )
      ..swift(
        'C:/Users/Mind/AppData/Local/Programs/Swift/Toolchains'
        '/6.4.0+Asserts/usr/bin',
      )
      ..registry[_userKey] = r'C:\Removed\Windows.sdk';
    final environment = fixture.environment(
      variables: {'LOCALAPPDATA': r'C:\Elsewhere'},
    );
    expect(await environment.swiftEnvironment(), {'SDKROOT': _userSdk});
    final check = (await environment.doctorChecks()).single;
    expect(check.status, DoctorStatus.success);
    expect(check.message, contains('Swift toolchain installation'));
    expect(fixture.processes.queries, [_userKey, _machineKey]);
  });

  test('leaves a valid inherited SDKROOT untouched', () async {
    fixture
      ..sdk(_environmentSdk)
      ..sdk(_userSdk)
      ..registry[_userKey] = _userSdk;
    final environment = fixture.environment(
      variables: {'SdkRoot': _environmentSdk},
    );
    expect(await environment.swiftEnvironment(), isEmpty);
    final check = (await environment.doctorChecks()).single;
    expect(check.status, DoctorStatus.success);
    expect(check.path, _environmentSdk);
    expect(fixture.processes.queries, isEmpty);
  });

  test('replaces and warns about an invalid inherited SDKROOT', () async {
    fixture
      ..directory(r'C:\Stale\Windows.sdk')
      ..sdk(_userSdk)
      ..registry[_userKey] = _userSdk;
    final environment = fixture.environment(
      variables: {'SDKROOT': r'C:\Stale\Windows.sdk'},
    );
    expect(await environment.swiftEnvironment(), {'SDKROOT': _userSdk});
    expect(await environment.swiftEnvironment(), {'SDKROOT': _userSdk});
    expect(
      fixture.output.messages.where(
        (message) => message.contains('is not a Windows SDK for Swift'),
      ),
      hasLength(1),
    );
    final check = (await environment.doctorChecks()).single;
    expect(check.status, DoctorStatus.warning);
    expect(check.message, contains(r'"C:\Stale\Windows.sdk"'));
    expect(check.message, contains('not a Windows SDK for Swift'));
    expect(check.path, _userSdk);
  });

  test('fails clearly when no SDK can be found', () async {
    fixture
      ..swift(
        r'C:\Users\Mind\AppData\Local\Programs\Swift\Toolchains'
        r'\6.4.0+Asserts\usr\bin',
      )
      ..registry[_userKey] = r'C:\Removed\Windows.sdk'
      ..failingRegistry.add(_machineKey);
    final environment = fixture.environment(
      variables: {'SDKROOT': r'C:\Missing'},
    );
    final error = await environment.swiftEnvironment().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    expect(error, isA<XcrossError>());
    final message = (error! as XcrossError).message;
    expect(message, contains(r'SDKROOT is set to "C:\Missing"'));
    expect(message, contains('Package.swift manifests'));
    expect(message, contains('$_userKey\\SDKROOT'));
    expect(message, contains('$_machineKey\\SDKROOT'));
    expect(
      message,
      contains(
        p.windows.join(
          _swiftRoot,
          'Platforms',
          '*',
          'Windows.platform',
          'Developer',
          'SDKs',
          'Windows.sdk',
        ),
      ),
    );
    expect(message, contains('Set SDKROOT to the Windows.sdk directory'));
    final check = (await environment.doctorChecks()).single;
    expect(check.status, DoctorStatus.failure);
    expect(check.message, message);
  });

  test('names the missing toolchain when swift is not on PATH', () async {
    final environment = fixture.environment();
    final check = (await environment.doctorChecks()).single;
    expect(check.status, DoctorStatus.failure);
    expect(check.message, startsWith('SDKROOT is not set'));
    expect(check.message, contains('swift is not on PATH'));
  });

  test('resolves once per run', () async {
    fixture
      ..sdk(_userSdk)
      ..registry[_userKey] = _userSdk;
    final environment = fixture.environment();
    await environment.swiftEnvironment();
    await environment.swiftEnvironment();
    await environment.doctorChecks();
    expect(fixture.processes.queries, [_userKey]);
  });
}

@internal
final class WindowsSdkRootFixture {
  WindowsSdkRootFixture(this.output)
    : backing = Directory.systemTemp.createTempSync('xcross-sdkroot-');
  final Directory backing;
  final TestLogOutput output;
  final Map<String, String> registry = {};
  final Set<String> failingRegistry = {};
  final List<String> path = [];
  late final WindowsSdkRootProcesses processes = WindowsSdkRootProcesses(
    registry,
    failingRegistry,
  );

  String physical(String logical) => p.joinAll([
    backing.path,
    ...p.windows
        .split(logical)
        .skip(1)
        .where((part) => part.isNotEmpty && part != '.'),
  ]);

  void directory(String logical) =>
      Directory(physical(logical)).createSync(recursive: true);

  void sdk(String logical) =>
      directory(p.windows.join(logical, 'usr', 'lib', 'swift', 'windows'));

  void swift(String bin) {
    directory(bin);
    File(physical(p.windows.join(bin, 'swift.exe'))).writeAsStringSync('');
    path.add(bin);
  }

  WindowsSwiftEnvironment environment({
    Map<String, String> variables = const {},
  }) {
    final environment = {
      'SystemRoot': r'C:\WINDOWS',
      'LOCALAPPDATA': r'C:\Users\Mind\AppData\Local',
      'PATHEXT': '.exe',
      'Path': path.join(';'),
      ...variables,
    };
    final host = WindowsHost(
      environment: environment,
      architecture: 'arm64',
      paths: WindowsPaths(environment: environment, currentDirectory: r'C:\'),
      fileSystem: WindowsSdkRootFileSystem(this),
      processes: processes,
    );
    return WindowsSwiftEnvironment(
      ProcessRunner(
        host,
        log: Log(output: output),
        stdinStream: const Stream.empty(),
        stdoutSink: testByteSink(),
        stderrSink: testByteSink(),
      ),
    );
  }

  void dispose() => backing.deleteSync(recursive: true);
}

@internal
final class WindowsSdkRootFileSystem implements HostFileSystemInterface {
  WindowsSdkRootFileSystem(this.fixture);
  final WindowsSdkRootFixture fixture;
  @override
  File file(String path) => File(fixture.physical(path));
  @override
  Directory directory(String path) => Directory(fixture.physical(path));
  @override
  Link link(String path) => Link(fixture.physical(path));
  @override
  void makeExecutable(String path) => throw StateError('Unexpected chmod');
  @override
  void setPermissions(String path, int mode) =>
      throw StateError('Unexpected chmod');
  @override
  Future<void> createArchiveLink(String destination, String target) async =>
      throw StateError('Unexpected link');
}

@internal
final class WindowsSdkRootProcesses implements HostProcessInterface {
  WindowsSdkRootProcesses(this.registry, this.failing);
  final Map<String, String> registry;
  final Set<String> failing;
  final List<String> queries = [];
  final List<String> executables = [];

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
  }) async {
    expect(arguments, [arguments[0], arguments[1], '/v', 'SDKROOT']);
    expect(arguments.first, 'query');
    executables.add(executable);
    final key = arguments[1];
    queries.add(key);
    if (failing.contains(key)) throw const ProcessException('reg.exe', []);
    final value = registry[key];
    return value == null
        ? WindowsSdkRootChild(
            1,
            '',
            'ERROR: The system was unable to find the specified registry '
                'key or value.',
          )
        : WindowsSdkRootChild(
            0,
            '\r\n$key\r\n    SDKROOT    '
                '${value.contains('%') ? 'REG_EXPAND_SZ' : 'REG_SZ'}    '
                '$value\r\n\r\n',
            '',
          );
  }

  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) async => throw StateError('Unexpected termination');

  @override
  Future<String?> findOnShellPath(
    String name, {
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async => null;
}

@internal
final class WindowsSdkRootChild implements Process {
  WindowsSdkRootChild(this.code, this.output, this.errors);
  final int code;
  final String output;
  final String errors;
  @override
  Future<int> get exitCode async => code;
  @override
  Stream<List<int>> get stdout => Stream.value(utf8.encode(output));
  @override
  Stream<List<int>> get stderr => Stream.value(utf8.encode(errors));
  @override
  IOSink get stdin => testByteSink();
  @override
  int get pid => 7;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      throw StateError('Unexpected kill');
}
