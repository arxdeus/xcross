import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/shared/appstoreconnect/asc_config.dart';
import 'package:args/command_runner.dart';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:dart_mobile_device/shared/device/models/device.dart';
import 'package:dart_mobile_device/shared/diagnostics/device_probe.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_build_platform.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/composition/cli/doctor_sections.dart';
import 'package:xcross/src/composition/cli/runner.dart';
import 'package:xcross/src/shared/cli/basic/doctor_command.dart';
import 'package:xcross/src/shared/cli/basic/doctor_environment_checks.dart';
import 'package:xcross/src/shared/cli/basic/doctor_models.dart';
import 'package:xcross/src/shared/config/config.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';

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
        final results = await checks.deployment();
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

  test('doctor is a Flutter and Compose subcommand, not a top-level one', () {
    final runner = XcrossCli.buildRunner(
      testApplication(),
      configTerminal: TestTerminal(),
    );

    expect(runner.commands.keys, isNot(contains('doctor')));
    expect(runner.commands['flutter']!.subcommands.keys, contains('doctor'));
    expect(runner.commands['compose']!.subcommands.keys, contains('doctor'));
    expect(
      runner.commands['flutter']!.subcommands['doctor']!.description,
      contains('Flutter'),
    );
    expect(
      runner.commands['compose']!.subcommands['doctor']!.description,
      contains('Compose'),
    );
  });

  test('each framework examines only its own sections', () {
    final sections = doctorSections(testRuntime(), '/project');

    expect(sections.flutter.map((section) => section.title), [
      'Flutter project',
      'iOS toolchain',
      'Deployment',
    ]);
    expect(sections.compose.map((section) => section.title), [
      'Compose project',
      'Compose toolchain',
      'Deployment',
    ]);
  });

  test('section header carries the worst status of its checks', () {
    final log = ansiLog();
    expect(
      DoctorCommand.formatSection('iOS toolchain', const [
        DoctorCheck.success('swift', 'Found', path: '/bin/swift'),
        DoctorCheck.warning('iOS linker', 'old'),
      ], log: log),
      '\u001b[33m[!]\u001b[0m \u001b[1miOS toolchain\u001b[0m\n'
      '    \u001b[32m✓\u001b[0m swift       \u001b[2m/bin/swift\u001b[22m\n'
      '    \u001b[33m!\u001b[0m iOS linker  old',
    );
    expect(
      DoctorCommand.formatSection('Deployment', const [
        DoctorCheck.failure('Device tools', 'missing'),
        DoctorCheck.warning('Device', 'none'),
      ], log: log),
      startsWith('\u001b[31m[✗]\u001b[0m'),
    );
  });

  test('aligns check names and dims locations below messages', () {
    expect(
      DoctorCommand.formatSection('iOS toolchain', const [
        DoctorCheck.success('swift', 'Found', path: '/bin/swift'),
        DoctorCheck.success('Darwin SDK', 'Installed', path: '/sdk'),
        DoctorCheck.failure('Swift version', 'Too old.\nUpgrade Swift.'),
      ], log: testLog()),
      '[✗] iOS toolchain\n'
      '    ✓ swift          /bin/swift\n'
      '    ✓ Darwin SDK     Installed\n'
      '                     /sdk\n'
      '    ✗ Swift version  Too old.\n'
      '                     Upgrade Swift.',
    );
  });

  test('warnings do not fail doctor', () async {
    final lines = <String>[];
    final runner = doctorRunner(lines, [
      DoctorSection(
        'Flutter project',
        () async => const [DoctorCheck.warning('Project', 'No pubspec.yaml.')],
      ),
    ]);

    await runner.run(['doctor']);

    expect(lines, [
      '[!] Flutter project\n    ! Project  No pubspec.yaml.',
      '',
      'Doctor found 1 warning.',
    ]);
  });

  test('a healthy doctor reports no issues', () async {
    final lines = <String>[];
    final runner = doctorRunner(lines, [
      DoctorSection(
        'Compose project',
        () async => const [DoctorCheck.success('Project', 'composeApp')],
      ),
    ]);

    await runner.run(['doctor']);

    expect(lines.last, 'No issues found.');
  });

  test('failures are all reported across sections and fail doctor', () async {
    final lines = <String>[];
    final runner = doctorRunner(lines, [
      DoctorSection(
        'iOS toolchain',
        () async => const [
          DoctorCheck.failure('swift', 'Not found.'),
          DoctorCheck.success('Darwin SDK', 'Installed'),
        ],
      ),
      DoctorSection('Deployment', () => throw StateError('probe broke')),
      DoctorSection(
        'Flutter project',
        () async => const [DoctorCheck.warning('Project', 'none')],
      ),
    ]);

    await expectLater(
      runner.run(['doctor']),
      throwsA(
        isA<XcrossError>().having(
          (error) => error.message,
          'message',
          'Doctor found 2 failures and 1 warning.',
        ),
      ),
    );
    expect(lines, [
      [
        '[✗] iOS toolchain',
        '    ✗ swift       Not found.',
        '    ✓ Darwin SDK  Installed',
      ].join('\n'),
      '',
      '[✗] Deployment\n    ✗ Deployment  Bad state: probe broke',
      '',
      '[!] Flutter project\n    ! Project  none',
      '',
    ]);
  });

  test(
    'Flutter doctor outside a project still checks the Flutter SDK',
    () async {
      final checks = await doctorSections(
        testRuntime(
          configuration: XcrossConfig(),
          fileSystem: logicalProjectFiles(),
        ),
        '/empty',
      ).flutterProject();

      expect(checks.map((check) => (check.name, check.status)), [
        ('Project', DoctorStatus.warning),
        ('Flutter SDK', DoctorStatus.failure),
      ]);
    },
  );

  test('Compose doctor outside a project is a warning', () async {
    final checks = await doctorSections(
      testRuntime(fileSystem: logicalProjectFiles()),
      '/empty',
    ).composeProject();

    expect(checks.single.status, DoctorStatus.warning);
    expect(checks.single.message, contains('settings.gradle'));
  });

  group('Compose doctor Swift imports', () {
    late DoctorServiceFileSystem files;
    void write(String path, String content) => files.file(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);

    void project({required String swift, bool kotlinEntry = false}) {
      write('/project/settings.gradle.kts', 'include(":shared")');
      write(
        '/project/shared/build.gradle.kts',
        'kotlin { iosArm64() { binaries.framework { baseName = "Shared" } } }',
      );
      if (kotlinEntry) {
        write(
          '/project/shared/src/iosMain/kotlin/Main.kt',
          'fun MainViewController() = ComposeUIViewController { }',
        );
      }
      write(
        '/project/iosApp/App.swift',
        '@main\nstruct DemoApp: App {}\n$swift',
      );
    }

    void installSdk({bool frameworks = true}) {
      for (final m in ['info.json', 'swift-sdk.json', 'toolset.json']) {
        write('/bundle/$m', '{}');
      }
      write(
        '/bundle/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/'
            'iphoneos/layouts-arm64.yaml',
        'x',
      );
      write(
        '/bundle/Developer/Runtimes/XcodeDefault.xctoolchain/usr/bin/'
            'layouts-arm64.yaml',
        'x',
      );
      const sdk =
          '/bundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs'
          '/iPhoneOS26.0.sdk/System/Library/Frameworks';
      if (!frameworks) return;
      files
          .directory('$sdk/UIKit.framework/Modules')
          .createSync(recursive: true);
    }

    Future<List<DoctorCheck>> run() {
      final runtime = testRuntime(fileSystem: files);
      final sections = DoctorSections(
        runtime,
        projectRoot: '/project',
        environment: DoctorEnvironmentChecks(
          hostPlatform: runtime.host,
          buildPlatform: const IPhoneBuildPlatform(),
          appleHostServices: runtime.appleHostServices,
          runner: runtime.runner,
          repository: DarwinSdkRepository(
            runtime.host,
            log: testLog(),
            installBundle: '/bundle',
          ),
          toolchain: runtime.darwinToolchain,
          deviceDiagnostics: DoctorNamespaceDiagnostics(),
          sdkMismatch: (_) async => null,
          sdkToolchainIdentity: () async => {},
          createAppleHttpClient: () => throw StateError('Unexpected HTTP'),
        ),
      );
      return sections.composeProject();
    }

    setUp(() => files = logicalProjectFiles());

    test('succeeds when every import resolves', () async {
      project(swift: 'import UIKit\nimport Shared');
      installSdk();
      final check = (await run()).singleWhere((c) => c.name == 'Swift imports');
      expect(check.status, DoctorStatus.success);
      expect(check.message, contains('resolve'));
    });

    test('fails naming module and file:line', () async {
      project(swift: 'import UIKit\nimport Firebase');
      installSdk();
      final check = (await run()).singleWhere((c) => c.name == 'Swift imports');
      expect(check.status, DoctorStatus.failure);
      expect(check.message, contains('Firebase'));
      expect(check.message, contains('iosApp/App.swift:'));
    });

    test('success wording is singular, plural, and empty-aware', () async {
      installSdk();
      project(swift: '#if os(iOS)\nimport Firebase\n#endif');
      var check = (await run()).singleWhere((c) => c.name == 'Swift imports');
      expect(check.message, 'No unconditional imports to check');
      files
          .file('/project/iosApp/App.swift')
          .writeAsStringSync('@main\nstruct DemoApp: App {}\nimport UIKit');
      check = (await run()).singleWhere((c) => c.name == 'Swift imports');
      expect(check.message, '1 module resolves against the Darwin SDK');
      files
          .file('/project/iosApp/App.swift')
          .writeAsStringSync(
            '@main\nstruct DemoApp: App {}\nimport UIKit\nimport Shared',
          );
      check = (await run()).singleWhere((c) => c.name == 'Swift imports');
      expect(check.message, '2 modules resolve against the Darwin SDK');
    });

    test('a corrupt SDK degrades to a warning, not a crash', () async {
      project(swift: 'import UIKit');
      installSdk(frameworks: false);
      final check = (await run()).singleWhere((c) => c.name == 'Swift imports');
      expect(check.status, DoctorStatus.warning);
      expect(check.message, startsWith('Not checked'));
    });

    test('warns when the Darwin SDK is absent', () async {
      project(swift: 'import UIKit');
      final check = (await run()).singleWhere((c) => c.name == 'Swift imports');
      expect(check.status, DoctorStatus.warning);
    });

    test('non-Swift projects get no row', () async {
      project(swift: 'import Firebase', kotlinEntry: true);
      installSdk();
      final checks = await run();
      expect(checks.map((c) => c.name), isNot(contains('Swift imports')));
    });
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
    final checks = await fixture.checks.flutterToolchain();
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
    final checks = await fixture.checks.flutterToolchain();

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
      final checks = await fixture.checks.flutterToolchain();

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
    final checks = await fixture.checks.flutterToolchain();

    expect(
      checks.firstWhere((check) => check.name == 'iOS linker'),
      isA<DoctorCheck>()
          .having((check) => check.status, 'status', DoctorStatus.success)
          .having((check) => check.message, 'message', contains('LLD 19.1')),
    );
  });

  test('Flutter project reports only configured SDK resolution', () async {
    final files = logicalProjectFiles();
    files.file('/project/pubspec.yaml')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('name: demo');
    files.file('/project/lib/main.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('');

    final checks = await doctorSections(
      testRuntime(configuration: XcrossConfig(), fileSystem: files),
      '/project',
    ).flutterProject();
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
      final files = logicalProjectFiles();
      files.file('/project/pubspec.yaml')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('name: demo');
      files.file('/project/.dart_tool/package_config.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{"configVersion":2,"packages":[]}');
      final runtime = testRuntime(
        configuration: XcrossConfig(),
        fileSystem: files,
      );
      final inspector = doctorSections(runtime, '/project');
      expect(
        inspector.packageConfigs.fileSystem,
        same(runtime.host.fileSystem),
      );
      expect(inspector.packageConfigs.paths, same(runtime.host.paths.context));
      final checks = await inspector.flutterProject();
      final packages = checks.singleWhere((check) => check.name == 'Packages');
      expect(packages.status, DoctorStatus.success);
      expect(packages.path, '/project/.dart_tool/package_config.json');
    },
  );

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
}

@internal
DoctorSections<T> doctorSections<T extends PlatformHostInterface>(
  XcrossRuntime<T> runtime,
  String projectRoot,
) => DoctorSections(
  runtime,
  projectRoot: projectRoot,
  environment: DoctorEnvironmentChecks(
    hostPlatform: runtime.host,
    buildPlatform: const IPhoneBuildPlatform(),
    appleHostServices: runtime.appleHostServices,
    runner: runtime.runner,
    repository: runtime.sdkRepository,
    toolchain: runtime.darwinToolchain,
    deviceDiagnostics: DoctorNamespaceDiagnostics(),
    sdkMismatch: (_) async => null,
    sdkToolchainIdentity: () async => {},
    createAppleHttpClient: () => throw StateError('Unexpected HTTP'),
  ),
);

@internal
CommandRunner<void> doctorRunner(
  List<String> lines,
  List<DoctorSection> sections,
) => CommandRunner<void>('xcross', 'test')
  ..addCommand(
    DoctorCommand(
      framework: 'Flutter',
      sections: sections,
      log: testLog(),
      writeLine: lines.add,
    ),
  );

@internal
Log ansiLog() => Log(output: AnsiLogOutput());

@internal
final class AnsiLogOutput implements LogOutput {
  @override
  bool get supportsAnsi => true;
  @override
  int get terminalColumns => 80;
  @override
  void stdout(String message) {}
  @override
  void stderr(String message) {}
  @override
  void write(String message) {}
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

@internal
DoctorServiceFileSystem logicalProjectFiles() {
  final root = Directory.systemTemp.createTempSync('xcross-doctor-project-');
  addTearDown(() => root.deleteSync(recursive: true));
  return DoctorServiceFileSystem(p.posix, '/', root.path);
}
