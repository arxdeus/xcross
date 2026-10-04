import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/shared/appstoreconnect/asc_config.dart';
import 'package:args/command_runner.dart';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_util/cli_logging.dart';
import 'package:dart_mobile_device/shared/device/models/device.dart';
import 'package:dart_mobile_device/shared/diagnostics/device_probe.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_build_platform.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/composition/cli/doctor_project_checks.dart';
import 'package:xcross/src/composition/cli/runner.dart';
import 'package:xcross/src/shared/cli/basic/doctor_command.dart';
import 'package:xcross/src/shared/cli/basic/doctor_environment_checks.dart';
import 'package:xcross/src/shared/cli/basic/doctor_examiner.dart';
import 'package:xcross/src/shared/cli/basic/doctor_models.dart';
import 'package:xcross/src/shared/config/config.dart';
import 'package:xcross/src/shared/errors/errors.dart';

import '../log_fixture.dart';
import 'auth_fixture.dart';
import 'doctor_environment_checks_test.dart';
import 'runtime_fixture.dart';

void main() {
  for (final style in [p.Style.posix, p.Style.windows]) {
    test(
      'doctor credential detection uses selected namespace on $style',
      () async {
        final fixture = AuthNamespaceFixture(style: style);
        addTearDown(fixture.dispose);
        final runtime = testRuntime();
        final diagnostics = DoctorNamespaceDiagnostics();
        final checks = DoctorEnvironmentChecks(
          hostPlatform: runtime.host,
          buildPlatform: const IPhoneBuildPlatform(),
          appleHostServices: fixture.services,
          runner: runtime.runner,
          repository: runtime.sdkRepository,
          toolchain: runtime.darwinToolchain,
          deviceDiagnostics: diagnostics,
          sdkMismatch: (_) async => null,
          sdkToolchainIdentity: () async => {},
          createAppleHttpClient: () =>
              throw StateError('Unexpected authentication HTTP'),
        );
        final results = await checks.run();
        expect(results.first.status, DoctorStatus.success);
        expect(
          results
              .firstWhere((result) => result.name == 'Authentication')
              .message,
          contains('No credentials found'),
        );
        expect(
          fixture.fileSystem.acquisitions,
          contains(
            AscCredentials.defaultConfigPath(hostServices: fixture.services),
          ),
        );
        expect(diagnostics.discovered, isTrue);
      },
    );
  }

  test('doctor is registered by the top-level runner', () {
    expect(
      XcrossCli.buildRunner(
        testApplication(),
        configTerminal: TestTerminal(),
      ).commands.keys,
      contains('doctor'),
    );
  });

  test('colors status markers like Flutter doctor', () {
    expect(
      DoctorCommand.formatCheck(
        const DoctorCheck.success('SDK', 'ready'),
        ansi: Ansi(true),
      ),
      '\u001b[32m[✓]\u001b[0m SDK: ready',
    );
    expect(
      DoctorCommand.formatCheck(
        const DoctorCheck.warning('Project', 'missing'),
        ansi: Ansi(true),
      ),
      '\u001b[33m[!]\u001b[0m Project: missing',
    );
    expect(
      DoctorCommand.formatCheck(
        const DoctorCheck.failure('Swift', 'missing'),
        ansi: Ansi(true),
      ),
      '\u001b[31m[✗]\u001b[0m Swift: missing',
    );
  });

  test('prints a path dimmed below its status line', () {
    expect(
      DoctorCommand.formatCheck(
        const DoctorCheck.success('Flutter SDK', 'Found', path: '/opt/flutter'),
        ansi: Ansi(true),
        dim: (value) => '<dim>$value</dim>',
      ),
      '\u001b[32m[✓]\u001b[0m Flutter SDK: Found\n'
      '    <dim>/opt/flutter</dim>',
    );
  });

  test('prints a path plainly below its status when ANSI is unavailable', () {
    expect(
      DoctorCommand.formatCheck(
        const DoctorCheck.success('Flutter SDK', 'Found', path: '/opt/flutter'),
        ansi: Ansi(false),
        dim: (value) => value,
      ),
      '[✓] Flutter SDK: Found\n    /opt/flutter',
    );
  });

  test('keeps status markers plain when ANSI is unavailable', () {
    expect(
      DoctorCommand.formatCheck(
        const DoctorCheck.failure('Swift', 'missing'),
        ansi: Ansi(false),
      ),
      '[✗] Swift: missing',
    );
  });

  test('warnings do not fail doctor', () async {
    final lines = <String>[];
    final command = DoctorCommand.withSeams(
      log: testLog(),
      examine: () async => const [
        DoctorCheck.warning('Project', 'No Flutter or Compose project found.'),
      ],
      writeLine: lines.add,
    );
    final runner = CommandRunner<void>('xcross', 'test')..addCommand(command);

    await runner.run(['doctor']);

    expect(lines, [
      '[!] Project: No Flutter or Compose project found.',
      'Doctor found 1 warning.',
    ]);
  });

  test('failures are all reported and fail doctor', () async {
    final lines = <String>[];
    final command = DoctorCommand.withSeams(
      log: testLog(),
      examine: () async => const [
        DoctorCheck.failure('Swift', 'swift was not found on PATH.'),
        DoctorCheck.success('SDK', 'Darwin SDK is installed.'),
        DoctorCheck.failure('Device tools', 'pymobiledevice3 was not found.'),
      ],
      writeLine: lines.add,
    );
    final runner = CommandRunner<void>('xcross', 'test')..addCommand(command);

    await expectLater(
      runner.run(['doctor']),
      throwsA(
        isA<XcrossError>().having(
          (error) => error.message,
          'message',
          'Doctor found 2 failures.',
        ),
      ),
    );
    expect(lines, [
      '[✗] Swift: swift was not found on PATH.',
      '[✓] SDK: Darwin SDK is installed.',
      '[✗] Device tools: pymobiledevice3 was not found.',
    ]);
  });

  test('missing project is a warning', () async {
    final examiner = DoctorExaminer.withSeams(
      hostChecks: () async => const [],
      detectProject: () async => null,
      projectChecks: (_) => throw StateError('project checks must not run'),
      runChecks: () async => const [],
    );

    final results = await examiner.examine();

    expect(results.single.status, DoctorStatus.warning);
    expect(results.single.name, 'Project');
  });

  test('detects Flutter and Compose projects from the current directory', () {
    final flutter = Directory.systemTemp.createTempSync('doctor_flutter');
    final compose = Directory.systemTemp.createTempSync('doctor_compose');
    addTearDown(() {
      flutter.deleteSync(recursive: true);
      compose.deleteSync(recursive: true);
    });
    File('${flutter.path}/pubspec.yaml').writeAsStringSync('name: demo');
    File('${compose.path}/settings.gradle.kts').writeAsStringSync('');

    expect(
      DoctorProjectChecks(testRuntime()).detect(flutter.path),
      isA<DoctorProject>().having(
        (project) => project.kind,
        'kind',
        DoctorProjectKind.flutter,
      ),
    );
    expect(
      DoctorProjectChecks(testRuntime()).detect(compose.path),
      isA<DoctorProject>().having(
        (project) => project.kind,
        'kind',
        DoctorProjectKind.compose,
      ),
    );
  });

  test('Windows host checks resolve PATHEXT executable names', () async {
    final fixture = DoctorServiceFixture(
      baseHost: WindowsHost(
        currentDirectory: r'C:\',
        environment: const {'USERPROFILE': r'C:\Users\Fixture'},
      ),
      abi: Abi.windowsX64,
    );
    addTearDown(fixture.dispose);
    fixture.lookup.tools.addAll({
      'swift': r'C:\Tools\swift.exe',
      'clang++': r'C:\Tools\clang++.exe',
      'llvm-ar': r'C:\Tools\llvm-ar.exe',
      'clang': r'C:\Program Files\LLVM\bin\clang.exe',
      'ld64.lld': r'C:\Program Files\LLVM\bin\ld64.lld.exe',
    });
    final checks = await fixture.checks.host();
    final requested = fixture.lookup.requests
        .take(3)
        .map((request) => request.$1);

    expect(requested, ['swift', 'clang++', 'llvm-ar']);
    expect(checks.first.status, DoctorStatus.success);
    expect(
      checks.firstWhere((check) => check.name == 'iOS clang').path,
      r'C:\Program Files\LLVM\bin\clang.exe',
    );
    expect(
      checks.firstWhere((check) => check.name == 'iOS linker').path,
      r'C:\Program Files\LLVM\bin\ld64.lld.exe',
    );
    expect(checks.where((check) => check.path != null), hasLength(6));
  });

  test('host checks report an unusable iOS compiler clearly', () async {
    final fixture = DoctorServiceFixture(
      baseHost: WindowsHost(
        currentDirectory: r'C:\',
        environment: const {'USERPROFILE': r'C:\Users\Fixture'},
      ),
      abi: Abi.windowsX64,
    );
    addTearDown(fixture.dispose);
    fixture.processes.clangFailure = 'No clang that can target iOS.';
    final checks = await fixture.checks.host();

    expect(
      checks.firstWhere((check) => check.name == 'iOS clang'),
      isA<DoctorCheck>()
          .having((check) => check.status, 'status', DoctorStatus.failure)
          .having(
            (check) => check.message,
            'message',
            contains('No clang that can target iOS.'),
          ),
    );
  });

  test(
    'host checks warn about a linker with the selector-stub defect',
    () async {
      final fixture = DoctorServiceFixture(
        baseHost: LinuxHost(
          currentDirectory: '/fixture',
          environment: const {'HOME': '/fixture'},
        ),
      );
      addTearDown(fixture.dispose);
      fixture.lookup.tools['ld64.lld'] = '/fixture/ld64.lld';
      fixture.processes.linkerVersion = 'LLD 18.1';
      final checks = await fixture.checks.host();

      expect(
        checks.firstWhere((check) => check.name == 'iOS linker'),
        isA<DoctorCheck>()
            .having((check) => check.status, 'status', DoctorStatus.warning)
            .having((check) => check.path, 'path', '/fixture/ld64.lld')
            .having((check) => check.message, 'message', contains('18.1')),
      );
    },
  );

  test('host checks report the linker version when it is healthy', () async {
    final fixture = DoctorServiceFixture(
      baseHost: LinuxHost(
        currentDirectory: '/fixture',
        environment: const {'HOME': '/fixture'},
      ),
    );
    addTearDown(fixture.dispose);
    final checks = await fixture.checks.host();

    expect(
      checks.firstWhere((check) => check.name == 'iOS linker'),
      isA<DoctorCheck>()
          .having((check) => check.status, 'status', DoctorStatus.success)
          .having((check) => check.message, 'message', contains('LLD 19.1')),
    );
  });

  test('Flutter project reports only configured SDK resolution', () async {
    final project = Directory.systemTemp.createTempSync(
      'xcross-doctor-flutter-',
    );
    addTearDown(() {
      project.deleteSync(recursive: true);
    });
    File('${project.path}/pubspec.yaml').writeAsStringSync('name: demo');
    Directory('${project.path}/lib').createSync();
    File('${project.path}/lib/main.dart').writeAsStringSync('');

    final checks = await DoctorProjectChecks(
      testRuntime(configuration: XcrossConfig()),
    ).examine(DoctorProject.flutter(project.path));
    final flutterSdkChecks = checks.where(
      (check) => check.name == 'Flutter SDK',
    );

    expect(flutterSdkChecks, hasLength(1));
    expect(flutterSdkChecks.single.status, DoctorStatus.failure);
    expect(flutterSdkChecks.single.message, contains('not configured'));
  });

  test(
    'Flutter package diagnostics use the selected filesystem resolver',
    () async {
      final project = Directory.systemTemp.createTempSync(
        'xcross-doctor-packages-',
      );
      addTearDown(() => project.deleteSync(recursive: true));
      File('${project.path}/pubspec.yaml').writeAsStringSync('name: demo');
      Directory('${project.path}/.dart_tool').createSync();
      final packageConfig = File(
        '${project.path}/.dart_tool/package_config.json',
      )..writeAsStringSync('{"configVersion":2,"packages":[]}');
      final runtime = testRuntime(configuration: XcrossConfig());
      final inspector = DoctorProjectChecks(runtime);
      expect(
        inspector.packageConfigs.fileSystem,
        same(runtime.host.fileSystem),
      );
      expect(inspector.packageConfigs.paths, same(runtime.host.paths.context));
      final checks = await inspector.examine(
        DoctorProject.flutter(project.path),
      );
      final packages = checks.singleWhere(
        (check) => check.name == 'Flutter packages',
      );
      expect(packages.status, DoctorStatus.success);
      expect(packages.path, packageConfig.path);
    },
  );

  test('Windows Flutter checks require the Flutter launcher', () async {
    final fixture = DoctorServiceFixture(
      baseHost: WindowsHost(
        currentDirectory: r'C:\',
        environment: const {'USERPROFILE': r'C:\Users\Fixture'},
      ),
      abi: Abi.windowsX64,
    );
    addTearDown(fixture.dispose);
    fixture.lookup.tools['flutter'] = r'C:\flutter\bin\flutter.bat';
    final checks = await fixture.checks.flutterTool();
    expect(fixture.lookup.requests.last.$1, 'flutter');

    expect(checks, isA<DoctorCheck>());
    expect(checks.status, DoctorStatus.success);
    expect(checks.path, r'C:\flutter\bin\flutter.bat');
  });

  test('device checks reject connected devices older than iOS 17', () async {
    final fixture = DoctorServiceFixture(
      baseHost: LinuxHost(
        currentDirectory: '/fixture',
        environment: const {'HOME': '/fixture'},
      ),
    );
    addTearDown(fixture.dispose);
    fixture.devices.versions.addAll({'old': 16, 'new': 17});
    final checks = await fixture.checks.devices(const [
      Device(name: 'Old iPhone', udid: 'old', type: ConnectionType.usb),
      Device(name: 'New iPhone', udid: 'new', type: ConnectionType.usb),
    ]);

    expect(checks.map((check) => check.status), [
      DoctorStatus.failure,
      DoctorStatus.success,
    ]);
  });

  test(
    'default examiner validates a detected project without building it',
    () async {
      final calls = <String>[];
      final examiner = DoctorExaminer.withSeams(
        hostChecks: () async {
          calls.add('host');
          return const [DoctorCheck.success('Host', 'ready')];
        },
        detectProject: () async => const DoctorProject.flutter('/project'),
        projectChecks: (project) async {
          calls.add('project:${project.root}');
          return const [DoctorCheck.success('Flutter project', 'ready')];
        },
        runChecks: () async {
          calls.add('run');
          return const [DoctorCheck.warning('Device', 'not connected')];
        },
      );

      final results = await examiner.examine();

      expect(calls, ['host', 'project:/project', 'run']);
      expect(results.map((result) => result.name), [
        'Host',
        'Flutter project',
        'Device',
      ]);
    },
  );
}

@internal
final class DoctorNamespaceDiagnostics implements DeviceDiagnostics {
  bool discovered = false;
  @override
  Future<String> resolveExecutable() async => '/selected/pymd';
  @override
  Future<List<Device>> devices() async {
    discovered = true;
    return [];
  }

  @override
  Future<int?> osMajorVersion(Device device) async => 17;
}
