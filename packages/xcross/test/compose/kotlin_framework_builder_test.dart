import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/compose/compose.dart';
import 'package:xcross/src/errors.dart';

void main() {
  test(
    'builds debug framework with module klib, dependency libraries, and bundle id',
    () async {
      final fixture = _Fixture.create(ComposeHost.linuxX64)..createInputs();
      final calls = <_Call>[];
      addTearDown(fixture.dispose);

      final output =
          await KotlinFrameworkBuilder.withSeams(
            runChecked:
                (executable, arguments, {workingDirectory, environment}) async {
                  calls.add(
                    _Call(executable, arguments, workingDirectory, environment),
                  );
                  fixture.createProducedFramework('debugFramework');
                },
            prepareKonan: ({required project, required toolchain}) async =>
                fixture.prepared,
          ).build(
            project: fixture.project,
            options: const ComposeBuildOptions(
              bundleId: 'org.example.override',
            ),
            toolchain: fixture.toolchain,
            klib: fixture.klib,
          );

      expect(
        output,
        p.join(fixture.root, 'build', 'xcross-ios', 'Shared.framework'),
      );
      expect(File(p.join(output, 'Shared')).readAsStringSync(), 'binary');
      expect(
        File(p.join(output, 'Headers', 'Shared.h')).readAsStringSync(),
        'header',
      );
      expect(calls, hasLength(1));
      expect(calls.single.executable, fixture.toolchain.javaExecutable);
      expect(calls.single.workingDirectory, fixture.root);
      expect(calls.single.environment, fixture.preparedEnvironment);
      expect(
        calls.single.arguments,
        contains(
          '-Xoverride-konan-properties=${fixture.prepared.konanPropertyOverrides}',
        ),
      );
      expect(
        calls.single.arguments,
        containsAllInOrder(['-target', 'ios_arm64']),
      );
      expect(
        calls.single.arguments,
        containsAllInOrder(['-produce', 'framework']),
      );
      expect(
        calls.single.arguments,
        contains('-Xinclude=${fixture.moduleKlib}'),
      );
      expect(
        calls.single.arguments,
        contains('-Xbinary=bundleId=org.example.override'),
      );
      expect(
        calls.single.arguments,
        contains('-Xbinary=enableDebugTransparentStepping=false'),
      );
      expect(
        calls.single.arguments,
        containsAllInOrder([
          '-library',
          fixture.depOne,
          '-library',
          fixture.depTwo,
        ]),
      );
      expect(calls.single.arguments, isNot(contains('-opt')));
      expect(
        calls.single.arguments,
        containsAllInOrder([
          '-o',
          p.join(
            fixture.modulePath,
            'build',
            'bin',
            'iosArm64',
            'debugFramework',
            'Shared.framework',
          ),
        ]),
      );
    },
  );

  test('builds release framework with opt and project bundle id', () async {
    final fixture = _Fixture.create(ComposeHost.linuxX64)..createInputs();
    _Call? call;
    addTearDown(fixture.dispose);

    await KotlinFrameworkBuilder.withSeams(
      runChecked:
          (executable, arguments, {workingDirectory, environment}) async {
            call = _Call(executable, arguments, workingDirectory, environment);
            fixture.createProducedFramework('releaseFramework');
          },
      prepareKonan: ({required project, required toolchain}) async =>
          fixture.prepared,
    ).build(
      project: fixture.project,
      options: const ComposeBuildOptions(
        configuration: ComposeConfiguration.release,
      ),
      toolchain: fixture.toolchain,
      klib: fixture.klib,
    );

    expect(call!.arguments, contains('-opt'));
    expect(call!.arguments, contains('-Xbinary=bundleId=dev.example.shared'));
    expect(
      call!.arguments,
      contains('-Xbinary=enableDebugTransparentStepping=false'),
    );
    expect(
      call!.arguments,
      containsAllInOrder([
        '-o',
        p.join(
          fixture.modulePath,
          'build',
          'bin',
          'iosArm64',
          'releaseFramework',
          'Shared.framework',
        ),
      ]),
    );
  });

  test('invokes Java directly with a Kotlin argfile on Windows', () async {
    final fixture = _Fixture.create(ComposeHost.windowsX64)..createInputs();
    _Call? call;
    addTearDown(fixture.dispose);

    await KotlinFrameworkBuilder.withSeams(
      runChecked:
          (executable, arguments, {workingDirectory, environment}) async {
            call = _Call(executable, arguments, workingDirectory, environment);
            fixture.createProducedFramework('debugFramework');
          },
      prepareKonan: ({required project, required toolchain}) async =>
          fixture.prepared,
    ).build(
      project: fixture.project,
      options: const ComposeBuildOptions(),
      toolchain: fixture.toolchain,
      klib: fixture.klib,
    );

    expect(call!.executable, fixture.toolchain.javaExecutable);
    expect(
      call!.arguments.take(fixture.prepared.compilerArguments.length),
      fixture.prepared.compilerArguments,
    );
    expect(call!.arguments.last, startsWith('@'));
    expect(call!.arguments.join(' '), isNot(contains('cmd.exe')));
    final argFile = File(call!.arguments.last.substring(1));
    expect(argFile.existsSync(), isTrue);
    final contents = argFile.readAsStringSync();
    expect(contents, contains('-Xoverride-konan-properties='));
    expect(contents, contains('ios_arm64'));
    expect(contents, contains('bundleId=dev.example.shared'));
  });

  test('throws when Kotlin Native omits the framework binary', () async {
    final fixture = _Fixture.create(ComposeHost.linuxX64)..createInputs();
    addTearDown(fixture.dispose);

    await expectLater(
      KotlinFrameworkBuilder.withSeams(
        runChecked:
            (executable, arguments, {workingDirectory, environment}) async {
              Directory(
                p.join(fixture.producedFramework('debugFramework'), 'Headers'),
              ).createSync(recursive: true);
              File(
                p.join(
                  fixture.producedFramework('debugFramework'),
                  'Headers',
                  'Shared.h',
                ),
              ).writeAsStringSync('header');
            },
        prepareKonan: ({required project, required toolchain}) async =>
            fixture.prepared,
      ).build(
        project: fixture.project,
        options: const ComposeBuildOptions(),
        toolchain: fixture.toolchain,
        klib: fixture.klib,
      ),
      throwsA(isA<XcrossError>()),
    );
  });
  test('throws when Kotlin Native omits the framework header', () async {
    final fixture = _Fixture.create(ComposeHost.linuxX64)..createInputs();
    addTearDown(fixture.dispose);

    await expectLater(
      KotlinFrameworkBuilder.withSeams(
        runChecked:
            (executable, arguments, {workingDirectory, environment}) async {
              final framework = fixture.producedFramework('debugFramework');
              Directory(framework).createSync(recursive: true);
              File(p.join(framework, 'Shared')).writeAsStringSync('binary');
            },
        prepareKonan: ({required project, required toolchain}) async =>
            fixture.prepared,
      ).build(
        project: fixture.project,
        options: const ComposeBuildOptions(),
        toolchain: fixture.toolchain,
        klib: fixture.klib,
      ),
      throwsA(isA<XcrossError>()),
    );
  });

  test('replaces stale framework-only destination contents', () async {
    final fixture = _Fixture.create(ComposeHost.linuxX64)..createInputs();
    final destination = Directory(
      p.join(fixture.root, 'build', 'xcross-ios', 'Shared.framework'),
    )..createSync(recursive: true);
    File(p.join(destination.path, 'stale.txt')).writeAsStringSync('stale');
    addTearDown(fixture.dispose);

    final output =
        await KotlinFrameworkBuilder.withSeams(
          runChecked:
              (executable, arguments, {workingDirectory, environment}) async {
                fixture.createProducedFramework(
                  'debugFramework',
                  binary: 'fresh',
                );
              },
          prepareKonan: ({required project, required toolchain}) async =>
              fixture.prepared,
        ).build(
          project: fixture.project,
          options: const ComposeBuildOptions(),
          toolchain: fixture.toolchain,
          klib: fixture.klib,
        );

    expect(File(p.join(output, 'stale.txt')).existsSync(), isFalse);
    expect(File(p.join(output, 'Shared')).readAsStringSync(), 'fresh');
  });
}

final class _Fixture {
  _Fixture._(this.temp, this.host)
    : root = temp.path,
      modulePath = p.join(temp.path, 'shared'),
      kotlinHome = p.join(temp.path, 'kotlin-home'),
      javaHome = p.join(temp.path, 'jdk'),
      moduleKlib = p.join(
        temp.path,
        'shared',
        'build',
        'classes',
        'kotlin',
        'iosArm64',
        'main',
        'klib',
        'shared',
      ),
      depOne = p.join(temp.path, 'deps', 'compose.klib'),
      depTwo = p.join(temp.path, 'deps', 'coroutines.klib');

  factory _Fixture.create(ComposeHost host) {
    final temp = Directory.systemTemp.createTempSync(
      'xcross_framework_builder_test_',
    );
    return _Fixture._(temp, host);
  }

  final Directory temp;
  final ComposeHost host;
  final String root;
  final String modulePath;
  final String kotlinHome;
  final String javaHome;
  final String moduleKlib;
  final String depOne;
  final String depTwo;

  Map<String, String> get preparedEnvironment => {
    'KONAN_DATA_DIR': p.join(root, 'konan-cache'),
    'PATH': p.join(root, 'shims'),
  };

  PreparedKonanConfiguration get prepared => PreparedKonanConfiguration(
    kotlinHome: p.join(root, 'build', 'xcross-ios', 'toolchain', 'kotlin-home'),
    konanConfigPath: p.join(
      root,
      'build',
      'xcross-ios',
      'toolchain',
      'konan',
      'konan.properties',
    ),
    javaExecutable: toolchain.javaExecutable,
    compilerArguments: const [
      '-ea',
      'org.jetbrains.kotlin.cli.utilities.MainKt',
      'konanc',
    ],
    konanPropertyOverrides: 'targetSysRoot.ios_arm64=/sdk',
    environment: preparedEnvironment,
  );

  KmpProject get project => KmpProject(
    root: root,
    modulePath: modulePath,
    moduleName: 'shared',
    baseName: 'Shared',
    entryKind: KmpEntryKind.frameworkOnly,
    bundleId: 'dev.example.shared',
    appName: 'Example',
  );

  ComposeToolchain get toolchain => ComposeToolchain(
    host: host,
    kotlinHome: kotlinHome,
    konanCache: p.join(root, 'konan-cache'),
    konancExecutable: p.join(
      kotlinHome,
      'bin',
      host.isWindows ? 'konanc.bat' : 'konanc',
    ),
    javaHome: javaHome,
    javaExecutable: p.join(
      javaHome,
      'bin',
      host.isWindows ? 'java.exe' : 'java',
    ),
    gradleExecutable: host.isWindows ? 'gradle.bat' : 'gradle',
    swiftc: p.join(root, 'swiftc'),
    clang: p.join(root, 'clang'),
    ld64Lld: p.join(root, 'ld64.lld'),
    darwinSdkPath: p.join(root, 'sdk'),
    darwinSdkBundle: p.join(root, 'sdk-bundle'),
  );

  GradleKlibResult get klib => GradleKlibResult(
    moduleKlibPath: moduleKlib,
    dependencies: [depOne, depTwo],
  );

  void createInputs() {
    Directory(moduleKlib).createSync(recursive: true);
    Directory(depOne).createSync(recursive: true);
    Directory(depTwo).createSync(recursive: true);
    Directory(p.join(kotlinHome, 'bin')).createSync(recursive: true);
    File(toolchain.konancExecutable).writeAsStringSync('konanc');
  }

  String producedFramework(String configuration) => p.join(
    modulePath,
    'build',
    'bin',
    'iosArm64',
    configuration,
    'Shared.framework',
  );

  void createProducedFramework(
    String configuration, {
    String binary = 'binary',
  }) {
    final framework = producedFramework(configuration);
    Directory(p.join(framework, 'Headers')).createSync(recursive: true);
    File(p.join(framework, 'Shared')).writeAsStringSync(binary);
    File(p.join(framework, 'Headers', 'Shared.h')).writeAsStringSync('header');
  }

  Future<void> dispose() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  }
}

final class _Call {
  const _Call(
    this.executable,
    this.arguments,
    this.workingDirectory,
    this.environment,
  );

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String>? environment;
}
