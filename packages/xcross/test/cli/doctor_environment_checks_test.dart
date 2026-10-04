import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit_shared.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/cli/basic/doctor_environment_checks.dart';
import 'package:xcross/src/shared/cli/basic/doctor_models.dart';

import 'auth_fixture.dart' show AuthNamespaceIdentity, AuthNamespacePermissions;
import 'runtime_fixture.dart';

void main() {
  test(
    'doctor consumes selected host and explicit compiler directories',
    () async {
      final fixture = DoctorServiceFixture(
        baseHost: LinuxHost(
          currentDirectory: '/fixture',
          environment: const {'HOME': '/fixture'},
        ),
      );
      addTearDown(fixture.dispose);
      fixture.processes.linkerVersion = 'LLD 18.1.3';
      final checks = await fixture.checks.host();
      expect(fixture.lookup.requests.take(3).map((request) => request.$1), [
        'swift',
        'clang++',
        'llvm-ar',
      ]);
      expect(
        fixture.lookup.requests
            .take(3)
            .every((request) => request.$2.single == '/fixture/llvm'),
        isTrue,
      );
      expect(checks.map((check) => check.name), [
        'Host',
        'swift',
        'clang++',
        'llvm-ar',
        'iOS clang',
        'iOS linker',
        'Darwin SDK',
      ]);
      expect(checks.first.message, 'linux is supported.');
      expect(
        checks.firstWhere((check) => check.name == 'iOS linker').status,
        DoctorStatus.warning,
      );
    },
  );

  test('doctor reports missing tools without installer effects', () async {
    final fixture = DoctorServiceFixture(
      baseHost: LinuxHost(
        currentDirectory: '/fixture',
        environment: const {'HOME': '/fixture'},
      ),
      sdkInstalled: false,
      tools: const {},
    );
    addTearDown(fixture.dispose);
    final checks = await fixture.checks.host();
    expect(
      checks.where((check) => check.status == DoctorStatus.failure),
      hasLength(6),
    );
    expect(
      checks[1].message,
      'Not found. Run `xcross setup` after installing Swift.',
    );
    expect(checks[4].message, contains('Darwin SDK is not installed.'));
    expect(fixture.processes.calls, isEmpty);
  });

  test('doctor ignores unidentifiable SDK without probing Swift', () async {
    final fixture = DoctorServiceFixture(
      baseHost: LinuxHost(
        currentDirectory: '/fixture',
        environment: const {'HOME': '/fixture'},
      ),
      sdkInstalled: false,
    );
    addTearDown(fixture.dispose);
    fixture.sdkNamed('iPhoneOS.sdk');
    expect(await fixture.checks.swiftTooOldForSdk(fixture.bundle), isNull);
    expect(fixture.identityRequests, 0);
  });

  test(
    'doctor resolves device tools before authentication and discovery',
    () async {
      final fixture = DoctorServiceFixture(
        baseHost: LinuxHost(
          currentDirectory: '/fixture',
          environment: const {'HOME': '/fixture'},
        ),
      );
      addTearDown(fixture.dispose);
      fixture.devices.resolveFailure = StateError(
        'fixture device tools missing',
      );
      fixture.fileSystem.acquisitions.clear();
      final checks = await fixture.checks.run();
      expect(checks.single.name, 'Device tools');
      expect(checks.single.message, 'Bad state: fixture device tools missing');
      expect(fixture.devices.calls, ['resolve']);
      expect(fixture.fileSystem.acquisitions, isEmpty);
    },
  );

  test(
    'doctor catches discovery version errors after authentication',
    () async {
      final fixture = DoctorServiceFixture(
        baseHost: LinuxHost(
          currentDirectory: '/fixture',
          environment: const {'HOME': '/fixture'},
        ),
      );
      addTearDown(fixture.dispose);
      fixture.devices.found = const [
        Device(name: 'Phone', udid: 'phone', type: ConnectionType.usb),
      ];
      fixture.devices.versionFailure = StateError(
        'fixture version unavailable',
      );
      final checks = await fixture.checks.run();
      expect(checks.map((check) => check.name), [
        'Device tools',
        'Authentication',
        'Device',
      ]);
      expect(checks.last.status, DoctorStatus.warning);
      expect(
        checks.last.message,
        'Discovery failed: Bad state: fixture version unavailable',
      );
      expect(fixture.devices.calls, ['resolve', 'devices', 'version:phone']);
    },
  );

  test('doctor preserves unknown, old and supported device messages', () async {
    final fixture = DoctorServiceFixture(
      baseHost: LinuxHost(
        currentDirectory: '/fixture',
        environment: const {'HOME': '/fixture'},
      ),
    );
    addTearDown(fixture.dispose);
    fixture.devices.versions.addAll({'unknown': null, 'old': 16, 'new': 17});
    final checks = await fixture.checks.devices(const [
      Device(name: 'Unknown', udid: 'unknown', type: ConnectionType.usb),
      Device(name: 'Old', udid: 'old', type: ConnectionType.usb),
      Device(name: 'New', udid: 'new', type: ConnectionType.usb),
    ]);
    expect(checks.map((check) => check.status), [
      DoctorStatus.warning,
      DoctorStatus.failure,
      DoctorStatus.success,
    ]);
    expect(checks.map((check) => check.message), [
      'Unknown (unknown): could not read the iOS version.',
      'Old (old) runs iOS 16; iOS 17 or later is required.',
      'New (new) runs iOS 17.',
    ]);
    expect(fixture.devices.calls, [
      'version:unknown',
      'version:old',
      'version:new',
    ]);
  });
}

final class DoctorServiceFixture {
  DoctorServiceFixture({
    required PlatformHostInterface baseHost,
    Abi abi = Abi.linuxX64,
    Map<String, String>? tools,
    bool sdkInstalled = true,
  }) {
    root = Directory.systemTemp.createTempSync('xcross-doctor-services-');
    final logicalRoot = baseHost.paths.context.current;
    fileSystem = DoctorServiceFileSystem(
      baseHost.paths.context,
      logicalRoot,
      root.path,
    );
    processes = DoctorServiceProcesses();
    host = DoctorServiceHost(baseHost, fileSystem, processes);
    final paths = host.paths.context;
    bundle = paths.join(logicalRoot, 'bundle');
    final log = testLog();
    lookup = DoctorServiceLookup(
      host,
      tools ??
          {
            for (final name in [
              'swift',
              'clang++',
              'llvm-ar',
              'clang',
              'ld64.lld',
            ])
              name: paths.join(
                logicalRoot,
                'bin',
                host.paths.executableName(name),
              ),
            'flutter': paths.join(
              logicalRoot,
              'flutter',
              host.paths.executableName('flutter', extension: '.bat'),
            ),
          },
    );
    runner = ProcessRunner(
      host,
      log: log,
      toolLookup: lookup,
      stdinStream: const Stream.empty(),
      stdoutSink: testByteSink(),
      stderrSink: testByteSink(),
    );
    repository = DarwinSdkRepository(host, log: log, installBundle: bundle);
    toolchain = DarwinToolchainResolver(
      runner,
      DoctorServiceLocations(paths.join(logicalRoot, 'llvm')),
    );
    devices = DoctorServiceDevices();
    checks = DoctorEnvironmentChecks(
      hostPlatform: host,
      runner: runner,
      repository: repository,
      toolchain: toolchain,
      buildPlatform: const IPhoneBuildPlatform(),
      deviceDiagnostics: devices,
      appleHostServices: AppleHostServices(
        host: host,
        abi: abi,
        machineIdentity: const AuthNamespaceIdentity(),
        permissions: AuthNamespacePermissions(),
      ),
      sdkMismatch: sdkMismatch,
      sdkToolchainIdentity: sdkIdentity,
      createAppleHttpClient: () => throw StateError('Unexpected doctor HTTP'),
    );
    if (sdkInstalled) installSdk();
  }

  late final Directory root;
  late final DoctorServiceFileSystem fileSystem;
  late final DoctorServiceProcesses processes;
  late final DoctorServiceHost host;
  late final DoctorServiceLookup lookup;
  late final ProcessRunner<DoctorServiceHost> runner;
  late final DarwinSdkRepository<DoctorServiceHost> repository;
  late final DarwinToolchainResolver<DoctorServiceHost> toolchain;
  late final DoctorServiceDevices devices;
  late final DoctorEnvironmentChecks<DoctorServiceHost> checks;
  late final String bundle;
  String swiftVersion = 'Swift version 6.4';
  String? mismatch;
  Error? identityFailure;
  int identityRequests = 0;

  Future<String?> sdkMismatch(String bundle) async => mismatch;
  Future<Map<String, String>> sdkIdentity() async {
    identityRequests++;
    if (identityFailure case final error?) throw error;
    return {
      'swift': lookup.tools['swift'] ?? '/fixture/swift',
      'version': swiftVersion,
    };
  }

  void sdkNamed(String name) => fileSystem
      .directory(
        host.paths.context.join(
          bundle,
          'Developer',
          'Platforms',
          'iPhoneOS.platform',
          'Developer',
          'SDKs',
          name,
        ),
      )
      .createSync(recursive: true);

  void installSdk({String name = 'iPhoneOS26.0.sdk'}) {
    final paths = host.paths.context;
    final sdk = paths.join(
      bundle,
      'Developer',
      'Platforms',
      'iPhoneOS.platform',
      'Developer',
      'SDKs',
      name,
    );
    fileSystem
        .directory(paths.join(sdk, 'System', 'Library', 'Frameworks'))
        .createSync(recursive: true);
    for (final metadata in ['info.json', 'swift-sdk.json', 'toolset.json']) {
      fileSystem.file(paths.join(bundle, metadata)).writeAsStringSync('{}');
    }
    for (final relative in [
      [
        'Developer',
        'Toolchains',
        'XcodeDefault.xctoolchain',
        'usr',
        'lib',
        'swift',
        'iphoneos',
        'layouts-arm64.yaml',
      ],
      [
        'Developer',
        'Runtimes',
        'XcodeDefault.xctoolchain',
        'usr',
        'bin',
        'layouts-arm64.yaml',
      ],
    ]) {
      final file = fileSystem.file(paths.joinAll([bundle, ...relative]));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('fixture-layout');
    }
  }

  void dispose() => root.deleteSync(recursive: true);
}

final class DoctorServiceHost implements PlatformHostInterface {
  const DoctorServiceHost(this.base, this.fileSystem, this.processes);
  final PlatformHostInterface base;
  @override
  final HostFileSystemInterface fileSystem;
  @override
  final HostProcessInterface processes;
  @override
  String get name => base.name;
  @override
  String get architecture => base.architecture;
  @override
  HostPathsInterface get paths => base.paths;
  @override
  HostEnvironmentInterface get environment => base.environment;
}

final class DoctorServiceFileSystem implements HostFileSystemInterface {
  DoctorServiceFileSystem(this.paths, this.logicalRoot, this.backingRoot);
  final p.Context paths;
  final String logicalRoot;
  final String backingRoot;
  final List<String> acquisitions = [];
  String physical(String path) {
    if (path != logicalRoot && !paths.isWithin(logicalRoot, path)) {
      throw StateError('Unexpected diagnostic acquisition $path');
    }
    acquisitions.add(path);
    return p.joinAll([
      backingRoot,
      ...paths
          .split(paths.relative(path, from: logicalRoot))
          .where((part) => part != '.'),
    ]);
  }

  @override
  File file(String path) => File(physical(path));
  @override
  Directory directory(String path) => Directory(physical(path));
  @override
  Link link(String path) => Link(physical(path));
  @override
  void makeExecutable(String path) =>
      throw StateError('Unexpected diagnostic chmod');
  @override
  void setPermissions(String path, int mode) =>
      throw StateError('Unexpected diagnostic permissions');
  @override
  Future<void> createArchiveLink(String destination, String target) async =>
      throw StateError('Unexpected diagnostic install');
}

final class DoctorServiceLocations
    implements DarwinToolchainLocationsInterface {
  const DoctorServiceLocations(this.directory);
  final String directory;
  @override
  List<String> llvmToolDirectories() => [directory];
  @override
  String get clangInstallationHint => 'fixture clang installation';
  @override
  String get linkerInstallationHint => 'fixture linker installation';
}

final class DoctorServiceLookup
    implements ProcessToolLookupInterface<DoctorServiceHost> {
  DoctorServiceLookup(this.host, Map<String, String> tools)
    : tools = Map.of(tools);
  @override
  final DoctorServiceHost host;
  final Map<String, String> tools;
  final List<(String, List<String>)> requests = [];
  @override
  ProcessConfiguration? get configuration => null;
  @override
  Map<String, String> get effectiveEnvironment => host.environment.values;
  @override
  String resolveExecutable(String executable) => executable;
  @override
  String hostExecutableName(String name, {String extension = '.exe'}) =>
      host.paths.executableName(name, extension: extension);
  @override
  String? environmentValue(Map<String, String> environment, String name) =>
      host.environment.lookup(environment, name);
  @override
  bool isSwiftlyProxy(String path) => false;
  @override
  Future<String?> which(
    String name, {
    Map<String, String>? environment,
    bool Function(String)? accept,
    Iterable<String> extraDirectories = const [],
    bool useConfiguration = true,
  }) async => (await whichAll(
    name,
    environment: environment,
    accept: accept,
    extraDirectories: extraDirectories,
    useConfiguration: useConfiguration,
  )).firstOrNull;
  @override
  Future<List<String>> whichAll(
    String name, {
    Map<String, String>? environment,
    bool Function(String)? accept,
    Iterable<String> extraDirectories = const [],
    bool useConfiguration = true,
  }) async {
    requests.add((name, extraDirectories.toList()));
    final path = tools[name];
    return path == null || (accept != null && !accept(path)) ? [] : [path];
  }

  @override
  Future<String> locateTool(
    String name, {
    Iterable<String> extraDirectories = const [],
  }) async =>
      await which(name, extraDirectories: extraDirectories) ??
      (throw StateError('Fixture tool missing: $name'));
}

final class DoctorServiceProcesses implements HostProcessInterface {
  String linkerVersion = 'LLD 19.1';
  String? clangFailure;
  final List<(String, List<String>)> calls = [];
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
    calls.add((executable, List.of(arguments)));
    if (arguments.contains('-###')) {
      if (clangFailure case final error?) throw StateError(error);
    }
    return DoctorServiceProcess(
      arguments.contains('--version') ? linkerVersion : '',
      'fixture missing probe input',
    );
  }

  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) async => throw StateError('Unexpected diagnostic termination');
  @override
  Future<String?> findOnShellPath(
    String name, {
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async => null;
}

final class DoctorServiceProcess implements Process {
  DoctorServiceProcess(this.output, this.errors);
  final String output;
  final String errors;
  @override
  Stream<List<int>> get stdout => Stream.value(utf8.encode(output));
  @override
  Stream<List<int>> get stderr => Stream.value(utf8.encode(errors));
  @override
  IOSink get stdin => testByteSink();
  @override
  Future<int> get exitCode async => 1;
  @override
  int get pid => 42;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      throw StateError('Unexpected diagnostic kill');
}

final class DoctorServiceDevices implements DeviceDiagnostics {
  Error? resolveFailure;
  Error? versionFailure;
  List<Device> found = [];
  final Map<String, int?> versions = {};
  final List<String> calls = [];
  @override
  Future<String> resolveExecutable() async {
    calls.add('resolve');
    if (resolveFailure case final error?) throw error;
    return '/fixture/pymd';
  }

  @override
  Future<List<Device>> devices() async {
    calls.add('devices');
    return found;
  }

  @override
  Future<int?> osMajorVersion(Device device) async {
    calls.add('version:${device.udid}');
    if (versionFailure case final error?) throw error;
    return versions[device.udid];
  }
}
