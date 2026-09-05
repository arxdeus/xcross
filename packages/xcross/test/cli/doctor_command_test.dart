import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_util/cli_logging.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/doctor_command.dart';
import 'package:xcross/src/cli/basic/doctor_environment_checks.dart';
import 'package:xcross/src/cli/basic/doctor_project_checks.dart';
import 'package:xcross/src/cli/runner.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/flutter/build/flutter_packer.dart';

void main() {
  test('doctor is registered by the top-level runner', () {
    expect(XcrossCli.buildRunner().commands.keys, contains('doctor'));
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
      DoctorExaminer.detectProjectAt(flutter.path),
      isA<DoctorProject>().having(
        (project) => project.kind,
        'kind',
        DoctorProjectKind.flutter,
      ),
    );
    expect(
      DoctorExaminer.detectProjectAt(compose.path),
      isA<DoctorProject>().having(
        (project) => project.kind,
        'kind',
        DoctorProjectKind.compose,
      ),
    );
  });

  test('Windows host checks resolve PATHEXT executable names', () async {
    final requested = <String>[];
    final checks = await DoctorEnvironmentChecks.hostWithSeams(
      operatingSystem: 'windows',
      windows: true,
      locateTool: (name, {windows, accept, extraDirectories = const []}) async {
        requested.add(name);
        return 'C:\\Tools\\$name.exe';
      },
      iosClang: () async => r'C:\Program Files\LLVM\bin\clang.exe',
      iosLinker: () async => r'C:\Program Files\LLVM\bin\ld64.lld.exe',
      darwinSdk: () async => const DoctorCheck.success(
        'Darwin SDK',
        'Installed',
        path: r'C:\xcross\sdk',
      ),
    );

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
    final checks = await DoctorEnvironmentChecks.hostWithSeams(
      operatingSystem: 'windows',
      windows: true,
      locateTool:
          (name, {windows, accept, extraDirectories = const []}) async =>
              'C:\\Tools\\$name.exe',
      iosClang: () async => throw StateError('No clang that can target iOS.'),
      iosLinker: () async => r'C:\LLVM\bin\ld64.lld.exe',
      darwinSdk: () async =>
          const DoctorCheck.success('Darwin SDK', 'Installed'),
    );

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
      final checks = await DoctorEnvironmentChecks.hostWithSeams(
        operatingSystem: 'linux',
        windows: false,
        locateTool:
            (name, {windows, accept, extraDirectories = const []}) async =>
                '/usr/bin/$name',
        iosClang: () async => '/usr/bin/clang',
        iosLinker: () async => '/usr/bin/ld64.lld',
        iosLinkerDefect: (path) async =>
            'ld64.lld 18.1 miswires selector stubs',
        darwinSdk: () async =>
            const DoctorCheck.success('Darwin SDK', 'Installed'),
      );

      expect(
        checks.firstWhere((check) => check.name == 'iOS linker'),
        isA<DoctorCheck>()
            .having((check) => check.status, 'status', DoctorStatus.warning)
            .having((check) => check.path, 'path', '/usr/bin/ld64.lld')
            .having((check) => check.message, 'message', contains('18.1')),
      );
    },
  );

  test('Flutter project reports only configured SDK resolution', () async {
    final project = Directory.systemTemp.createTempSync(
      'xcross-doctor-flutter-',
    );
    addTearDown(() {
      FlutterPacker.resetFlutterRootOverride();
      project.deleteSync(recursive: true);
    });
    File('${project.path}/pubspec.yaml').writeAsStringSync('name: demo');
    Directory('${project.path}/lib').createSync();
    File('${project.path}/lib/main.dart').writeAsStringSync('');
    FlutterPacker.configureFlutterResolution(declarative: true);

    final checks = await DoctorProjectChecks.examine(
      DoctorProject.flutter(project.path),
    );
    final flutterSdkChecks = checks.where(
      (check) => check.name == 'Flutter SDK',
    );

    expect(flutterSdkChecks, hasLength(1));
    expect(flutterSdkChecks.single.status, DoctorStatus.failure);
    expect(flutterSdkChecks.single.message, contains('not configured'));
  });

  test('Windows Flutter checks require the Flutter launcher', () async {
    final checks = await DoctorEnvironmentChecks.flutterToolWithSeams(
      windows: true,
      locateTool: (name, {windows, accept, extraDirectories = const []}) async {
        expect(name, 'flutter');
        expect(windows, isTrue);
        return r'C:\flutter\bin\flutter.bat';
      },
    );

    expect(checks, isA<DoctorCheck>());
    expect(checks.status, DoctorStatus.success);
    expect(checks.path, r'C:\flutter\bin\flutter.bat');
  });

  test('device checks reject connected devices older than iOS 17', () async {
    final checks = await DoctorExaminer.deviceChecks(const [
      Device(name: 'Old iPhone', udid: 'old', type: ConnectionType.usb),
      Device(name: 'New iPhone', udid: 'new', type: ConnectionType.usb),
    ], osMajorVersion: (device) async => device.udid == 'old' ? 16 : 17);

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
