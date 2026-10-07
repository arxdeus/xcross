import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/compose/build/gradle_klib_builder.dart';
import 'package:xcross/src/shared/compose/compose_host.dart';
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/target/shared/compose/compose_target.dart';

import 'support/compose_platforms.dart';

void main() {
  late ComposeTestSession session;
  setUp(() {
    session = createComposeTestSession();
  });
  tearDown(() => session.dispose());
  test('compiles simulator Gradle klib and only simulator resources', () async {
    final fixture =
        ComposeFixture.create(
            session,
            moduleName: 'app:shared',
            target: fixtureSimulatorTargetFor(session.hosts.macosArm64),
          )
          ..createWrapper()
          ..createModuleKlib();
    addTearDown(fixture.dispose);
    final result = await GradleKlibBuilder.withSeams(
      fixture.toolchain.runner,
      runChecked:
          (executable, arguments, {workingDirectory, environment}) async {
            final script = File(
              arguments[arguments.indexOf('--init-script') + 1],
            ).readAsStringSync();
            expect(script, contains('if (path != ":app:shared")'));
            expect(
              script,
              contains('dependsOn("compileKotlinIosSimulatorArm64")'),
            );
            expect(script, contains('"iosSimulatorArm64ProcessResources"'));
            expect(script, contains('"iosSimulatorArm64AggregateResources"'));
            expect(script, isNot(contains('compileKotlinIosArm64')));
            File(environment!['XCROSS_DEPS_OUT']!).writeAsStringSync('');
          },
    ).build(project: fixture.project, toolchain: fixture.toolchain);
    expect(result.moduleKlibPath, contains('/iosSimulatorArm64/'));
  });

  test(
    'runs native macOS ARM64 Gradle with matching Java and Konan cache',
    () async {
      final fixture =
          ComposeFixture.create(
              session,
              moduleName: 'shared',
              target: fixtureIPhoneTargetFor(session.hosts.macosArm64),
            )
            ..createWrapper()
            ..createModuleKlib();
      addTearDown(fixture.dispose);
      var calls = 0;
      await GradleKlibBuilder.withSeams(
        fixture.toolchain.runner,
        runChecked:
            (executable, arguments, {workingDirectory, environment}) async {
              calls++;
              expect(executable, p.join(fixture.root, 'gradlew'));
              expect(arguments, contains(':shared:dumpIosDeps'));
              expect(environment!['JAVA_HOME'], fixture.toolchain.javaHome);
              expect(
                environment['KONAN_DATA_DIR'],
                fixture.toolchain.konanCache,
              );
              expect(
                environment['PATH'],
                startsWith('${p.join(fixture.toolchain.javaHome, 'bin')}:'),
              );
              File(environment['XCROSS_DEPS_OUT']!).writeAsStringSync('');
            },
      ).build(project: fixture.project, toolchain: fixture.toolchain);
      expect(calls, 1);
    },
  );

  test(
    'build compiles nested module and dumps filtered ios dependencies',
    () async {
      final fixture =
          ComposeFixture.create(
              session,
              moduleName: 'a:b',
              target: fixtureIPhoneTargetFor(session.hosts.linuxX64),
            )
            ..createWrapper()
            ..createModuleKlib();
      final externalKlib = Directory(
        p.join(fixture.root, 'external', 'compose.klib'),
      )..createSync(recursive: true);
      final normalizedExternal = p.normalize(
        p.join(externalKlib.path, '..', 'compose.klib'),
      );
      final platformKlib = Directory(
        p.join(
          fixture.kotlinHome,
          'klib',
          'platform',
          'ios_arm64',
          'UIKit.klib',
        ),
      )..createSync(recursive: true);
      final foreignPlatformKlib = Directory(
        p.join(
          fixture.root,
          'konan',
          'kotlin-native-prebuilt-windows-x86_64-2.4.0',
          'klib',
          'platform',
          'ios_arm64',
          'org.jetbrains.kotlin.native.platform.UIKit',
        ),
      )..createSync(recursive: true);
      File(
        p.join(foreignPlatformKlib.path, 'default', 'manifest'),
      ).createSync(recursive: true);
      final prefixConfusion = Directory('${fixture.kotlinHome}_other')
        ..createSync();
      final siblingKlib = Directory(
        p.join(prefixConfusion.path, 'compose.klib'),
      )..createSync(recursive: true);
      final calls = <ComposeCall>[];

      addTearDown(fixture.dispose);
      final result = await GradleKlibBuilder.withSeams(
        fixture.toolchain.runner,
        runChecked:
            (executable, arguments, {workingDirectory, environment}) async {
              calls.add(
                ComposeCall(
                  executable,
                  arguments,
                  workingDirectory,
                  environment,
                ),
              );
              if (arguments.contains(':a:b:dumpIosDeps')) {
                final initScript = File(
                  arguments[arguments.indexOf('--init-script') + 1],
                );
                final source = initScript.readAsStringSync();
                expect(
                  source,
                  contains('if (path != ":a:b") return@allprojects'),
                );
                expect(source, contains('tasks.register("dumpIosDeps")'));
                // Compose resources are refreshed in the same build, but only
                // where the project has the tasks.
                expect(source, contains('"iosArm64ProcessResources"'));
                expect(source, contains('"iosArm64AggregateResources"'));
                expect(source, contains('project.tasks.findByName(it)'));
                expect(source, contains('System.getenv("XCROSS_DEPS_OUT")'));
                File(environment!['XCROSS_DEPS_OUT']!).writeAsStringSync(
                  [
                    p.join(externalKlib.path, '..', 'compose.klib'),
                    externalKlib.path,
                    platformKlib.path,
                    foreignPlatformKlib.path,
                    siblingKlib.path,
                    p.join(fixture.root, 'missing.klib'),
                    p.join(fixture.root, 'not-klib.jar'),
                  ].join('\n'),
                );
              }
            },
      ).build(project: fixture.project, toolchain: fixture.toolchain);

      expect(result.moduleKlibPath, fixture.moduleKlibPath);
      expect(result.dependencies, [normalizedExternal, siblingKlib.path]);
      expect(calls, hasLength(1));
      expect(calls.single.executable, p.join(fixture.root, 'gradlew'));
      expect(calls.single.arguments, [
        ':a:b:dumpIosDeps',
        '-Pkotlin.native.enableKlibsCrossCompilation=true',
        '-Pxcross.depsOut=${p.join(p.dirname(calls.single.initScriptPath), 'iosDeps.txt')}',
        '--init-script',
        calls.single.initScriptPath,
        '--no-configuration-cache',
        '--console=plain',
      ]);
      expect(calls.single.workingDirectory, fixture.root);
      expect(File(calls.single.initScriptPath).existsSync(), isFalse);
      expect(File(calls.single.depsOutPath).existsSync(), isFalse);
    },
  );

  test(
    'keeps project klib directories and drops everything that is not a library',
    () async {
      // Regression: `api(project(":core"))` resolves to an extension-less klib
      // *directory* (…/klib/core). Filtering dependencies on a ".klib" suffix
      // dropped it, so the link ran without the module's own siblings and the
      // compiler reported unrelated internal errors (IrCompositeImpl in
      // EnumClassLowering, then "no function X in package Y" from ObjC export).
      final fixture =
          ComposeFixture.create(
              session,
              moduleName: 'app:shared',
              target: fixtureIPhoneTargetFor(session.hosts.linuxX64),
            )
            ..createWrapper()
            ..createModuleKlib();
      // Verified against a real `api(project(":core"))` build: Gradle hands the
      // compilation an extension-less *directory* whose `default/manifest` is
      // what identifies it as a library.
      final projectKlib = _unpackedKlib(
        p.join(
          fixture.root,
          'core',
          'build',
          'classes',
          'kotlin',
          'iosArm64',
          'main',
          'klib',
          'core',
        ),
      );
      // On the compile classpath too, and not a library: must not be passed.
      final compilerJar = File(
        p.join(
          fixture.kotlinHome,
          'konan',
          'lib',
          'kotlin-native-compiler-embeddable.jar',
        ),
      )..createSync(recursive: true);
      // Any other directory on the classpath is not a library either, and
      // naming the compiler jar alone would keep letting these through.
      final resourcesDir = Directory(
        p.join(fixture.root, 'core', 'build', 'processedResources'),
      )..createSync(recursive: true);
      final externalKlib = Directory(
        p.join(fixture.root, 'external', 'compose.klib'),
      )..createSync(recursive: true);

      addTearDown(fixture.dispose);

      final result = await GradleKlibBuilder.withSeams(
        fixture.toolchain.runner,
        runChecked:
            (executable, arguments, {workingDirectory, environment}) async {
              if (arguments.contains(':app:shared:dumpIosDeps')) {
                File(environment!['XCROSS_DEPS_OUT']!).writeAsStringSync(
                  [
                    projectKlib.path,
                    compilerJar.path,
                    resourcesDir.path,
                    externalKlib.path,
                  ].join('\n'),
                );
              }
            },
      ).build(project: fixture.project, toolchain: fixture.toolchain);

      expect(result.dependencies, [
        p.normalize(projectKlib.path),
        p.normalize(externalKlib.path),
      ]);
    },
  );

  // Modelled on a real `:shared:dumpIosDeps` dump (Kotlin 2.4.0, Compose
  // Multiplatform, one `api(project(":core"))`): 218 entries, of which 178 were
  // extension-less Konan platform directories, 39 were packed `.klib` files from
  // Maven, and exactly one was the project's own klib directory.
  test('handles the shape a real dependency dump has', () async {
    final fixture =
        ComposeFixture.create(
            session,
            moduleName: 'shared',
            target: fixtureIPhoneTargetFor(session.hosts.linuxX64),
          )
          ..createWrapper()
          ..createModuleKlib();
    addTearDown(fixture.dispose);

    // Konan's own libraries are unpacked directories without a `.klib` suffix,
    // and are dropped for being inside the toolchain, not for their shape.
    final platform = [
      for (final name in [
        'stdlib',
        'org.jetbrains.kotlin.native.platform.UIKit',
      ])
        _unpackedKlib(p.join(fixture.kotlinHome, 'klib', name)).path,
    ];
    // Maven dependencies arrive as packed files.
    final packed = [
      for (final name in ['runtime-iosArm64Main-1.9.0.klib', 'annotation.klib'])
        (File(p.join(fixture.root, 'm2', name))
              ..createSync(recursive: true)
              ..writeAsStringSync('packed'))
            .path,
    ];
    final projectKlib = _unpackedKlib(
      p.join(
        fixture.root,
        'core',
        'build',
        'classes',
        'kotlin',
        'iosArm64',
        'main',
        'klib',
        'core',
      ),
    ).path;

    final result = await GradleKlibBuilder.withSeams(
      fixture.toolchain.runner,
      runChecked:
          (executable, arguments, {workingDirectory, environment}) async {
            if (arguments.contains(':shared:dumpIosDeps')) {
              File(environment!['XCROSS_DEPS_OUT']!).writeAsStringSync(
                [...platform, ...packed, projectKlib].join('\n'),
              );
            }
          },
    ).build(project: fixture.project, toolchain: fixture.toolchain);

    expect(result.dependencies, [...packed, projectKlib]);
  });

  test('uses system Gradle when no wrapper exists', () async {
    final fixture = ComposeFixture.create(
      session,
      moduleName: 'shared',
      target: fixtureIPhoneTargetFor(session.hosts.linuxX64),
    )..createModuleKlib();
    final calls = <ComposeCall>[];
    addTearDown(fixture.dispose);

    await GradleKlibBuilder.withSeams(
      fixture.toolchain.runner,
      runChecked:
          (executable, arguments, {workingDirectory, environment}) async {
            calls.add(
              ComposeCall(executable, arguments, workingDirectory, environment),
            );
            if (arguments.contains(':shared:dumpIosDeps')) {
              File(environment!['XCROSS_DEPS_OUT']!).writeAsStringSync('');
            }
          },
    ).build(project: fixture.project, toolchain: fixture.toolchain);

    expect(calls.first.executable, 'gradle');
  });

  test(
    'wraps Windows batch gradle wrapper and uses Windows PATH separator',
    () async {
      final fixture =
          ComposeFixture.create(
              session,
              moduleName: 'shared',
              target: fixtureIPhoneTargetFor(session.hosts.windowsX64),
            )
            ..createWrapper()
            ..createModuleKlib();
      final calls = <ComposeCall>[];
      addTearDown(fixture.dispose);

      await GradleKlibBuilder.withSeams(
        fixture.toolchain.runner,
        runChecked:
            (executable, arguments, {workingDirectory, environment}) async {
              calls.add(
                ComposeCall(
                  executable,
                  arguments,
                  workingDirectory,
                  environment,
                ),
              );
              if (arguments.contains(':shared:dumpIosDeps')) {
                File(environment!['XCROSS_DEPS_OUT']!).writeAsStringSync('');
              }
            },
      ).build(project: fixture.project, toolchain: fixture.toolchain);

      expect(calls.first.executable, p.join(fixture.root, 'gradlew.bat'));
      expect(calls.first.arguments, contains(':shared:dumpIosDeps'));
      final path = calls.first.environment!['PATH']!;
      expect(path, startsWith('${p.join(fixture.javaHome, 'bin')};'));
    },
  );

  test('uses POSIX PATH separator for Linux hosts', () async {
    final fixture =
        ComposeFixture.create(
            session,
            moduleName: 'shared',
            target: fixtureIPhoneTargetFor(session.hosts.linuxX64),
          )
          ..createWrapper()
          ..createModuleKlib();
    ComposeCall? compile;
    addTearDown(fixture.dispose);

    await GradleKlibBuilder.withSeams(
      fixture.toolchain.runner,
      runChecked:
          (executable, arguments, {workingDirectory, environment}) async {
            compile ??= ComposeCall(
              executable,
              arguments,
              workingDirectory,
              environment,
            );
            if (arguments.contains(':shared:dumpIosDeps')) {
              File(environment!['XCROSS_DEPS_OUT']!).writeAsStringSync('');
            }
          },
    ).build(project: fixture.project, toolchain: fixture.toolchain);

    final compileCall = compile;
    expect(compileCall, isNotNull);
    expect(
      compileCall!.environment!['PATH'],
      startsWith('${p.join(fixture.javaHome, 'bin')}:'),
    );
  });

  test(
    'throws when module KLIB is missing and cleans temporary files',
    () async {
      final fixture = ComposeFixture.create(
        session,
        moduleName: 'shared',
        target: fixtureIPhoneTargetFor(session.hosts.linuxX64),
      )..createWrapper();
      ComposeCall? depsCall;
      addTearDown(fixture.dispose);

      await expectLater(
        GradleKlibBuilder.withSeams(
          fixture.toolchain.runner,
          runChecked:
              (executable, arguments, {workingDirectory, environment}) async {
                if (arguments.contains(':shared:dumpIosDeps')) {
                  depsCall = ComposeCall(
                    executable,
                    arguments,
                    workingDirectory,
                    environment,
                  );
                  File(environment!['XCROSS_DEPS_OUT']!).writeAsStringSync('');
                }
              },
        ).build(project: fixture.project, toolchain: fixture.toolchain),
        throwsA(isA<Exception>()),
      );

      expect(File(depsCall!.initScriptPath).existsSync(), isFalse);
      expect(File(depsCall!.depsOutPath).existsSync(), isFalse);
    },
  );

  test(
    'throws when dependency output is missing and cleans temporary files',
    () async {
      final fixture =
          ComposeFixture.create(
              session,
              moduleName: 'shared',
              target: fixtureIPhoneTargetFor(session.hosts.linuxX64),
            )
            ..createWrapper()
            ..createModuleKlib();
      ComposeCall? depsCall;
      addTearDown(fixture.dispose);

      await expectLater(
        GradleKlibBuilder.withSeams(
          fixture.toolchain.runner,
          runChecked:
              (executable, arguments, {workingDirectory, environment}) async {
                if (arguments.contains(':shared:dumpIosDeps')) {
                  depsCall = ComposeCall(
                    executable,
                    arguments,
                    workingDirectory,
                    environment,
                  );
                }
              },
        ).build(project: fixture.project, toolchain: fixture.toolchain),
        throwsA(isA<Exception>()),
      );

      expect(File(depsCall!.initScriptPath).existsSync(), isFalse);
      expect(File(depsCall!.depsOutPath).existsSync(), isFalse);
    },
  );

  test(
    'cleans temporary files when compile Gradle invocation throws',
    () async {
      final fixture = ComposeFixture.create(
        session,
        moduleName: 'shared',
        target: fixtureIPhoneTargetFor(session.hosts.linuxX64),
      )..createWrapper();
      String? depsOutPath;
      addTearDown(fixture.dispose);

      await expectLater(
        GradleKlibBuilder.withSeams(
          fixture.toolchain.runner,
          runChecked: (executable, arguments, {workingDirectory, environment}) {
            depsOutPath = environment!['XCROSS_DEPS_OUT'];
            throw StateError('compile failed');
          },
        ).build(project: fixture.project, toolchain: fixture.toolchain),
        throwsStateError,
      );

      expect(File(depsOutPath!).parent.existsSync(), isFalse);
    },
  );

  test(
    'cleans temporary files when dependency Gradle invocation throws',
    () async {
      final fixture = ComposeFixture.create(
        session,
        moduleName: 'shared',
        target: fixtureIPhoneTargetFor(session.hosts.linuxX64),
      )..createWrapper();
      ComposeCall? depsCall;
      addTearDown(fixture.dispose);

      await expectLater(
        GradleKlibBuilder.withSeams(
          fixture.toolchain.runner,
          runChecked:
              (executable, arguments, {workingDirectory, environment}) async {
                if (arguments.contains(':shared:dumpIosDeps')) {
                  depsCall = ComposeCall(
                    executable,
                    arguments,
                    workingDirectory,
                    environment,
                  );
                  throw StateError('deps failed');
                }
              },
        ).build(project: fixture.project, toolchain: fixture.toolchain),
        throwsStateError,
      );

      expect(File(depsCall!.initScriptPath).existsSync(), isFalse);
      expect(File(depsCall!.depsOutPath).existsSync(), isFalse);
    },
  );
}

@internal
final class ComposeFixture {
  ComposeFixture._(
    this.session,
    this.temp,
    this.root,
    this.moduleName,
    this.target,
  ) : modulePath = p.joinAll([root, ...moduleName.split(':')]),
      kotlinHome = p.join(root, 'kotlinc'),
      javaHome = p.join(root, 'jdk');
  final ComposeTestSession session;

  static ComposeFixture create(
    ComposeTestSession session, {
    required String moduleName,
    required ComposeTarget<PlatformHostInterface> target,
  }) {
    final temp = Directory.systemTemp.createTempSync(
      'xcross_gradle_builder_test_',
    );
    final fixture = ComposeFixture._(
      session,
      temp,
      temp.path,
      moduleName,
      target,
    );
    Directory(fixture.modulePath).createSync(recursive: true);
    return fixture;
  }

  final Directory temp;
  final String root;
  final String moduleName;
  final ComposeTarget<PlatformHostInterface> target;
  ComposeHost<PlatformHostInterface> get host => target.toolchainHost;
  final String modulePath;
  final String kotlinHome;
  final String javaHome;

  String get moduleLeaf => moduleName.split(':').last;
  String get moduleKlibPath => p.join(
    modulePath,
    'build',
    'classes',
    'kotlin',
    target.gradleTarget,
    'main',
    'klib',
    moduleLeaf,
  );

  KmpProject get project => KmpProject(
    root: root,
    modulePath: modulePath,
    moduleName: moduleName,
    baseName: 'Shared',
    entryKind: KmpEntryKind.frameworkOnly,
    bundleId: 'dev.example.app',
    appName: 'Example',
  );

  ComposeToolchain get toolchain => ComposeToolchain(
    log: session.fixtureLog,
    target: target,
    runner: ProcessRunner(
      log: session.fixtureLog,
      host.host,
      stdinStream: const Stream<List<int>>.empty(),
      stdoutSink: session.stdoutSink,
      stderrSink: session.stderrSink,
    ),
    kotlinHome: kotlinHome,
    konanCache: p.join(root, 'konan-cache'),
    konancExecutable: host.konancExecutable(kotlinHome),
    javaHome: javaHome,
    javaExecutable: host.javaExecutable(javaHome),
    gradleExecutable: host.host.paths.executableName(
      'gradle',
      extension: '.bat',
    ),
    swiftc: p.join(root, 'swiftc'),
    clang: p.join(root, 'clang'),
    ld64Lld: p.join(root, 'ld64.lld'),
    darwinSdkPath: p.join(root, 'sdk'),
    darwinSdkBundle: p.join(root, 'sdk-bundle'),
  );

  void createWrapper() {
    File(host.gradleWrapper(root)).writeAsStringSync('');
  }

  void createModuleKlib() {
    Directory(moduleKlibPath).createSync(recursive: true);
  }

  Future<void> dispose() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  }
}

/// Creates an unpacked KLIB at [path], the shape Gradle produces for a project
/// dependency: a directory whose `default/manifest` is what identifies it as a
/// library, since the directory name carries no `.klib` suffix.
Directory _unpackedKlib(String path) {
  final directory = Directory(path)..createSync(recursive: true);
  File(p.join(path, 'default', 'manifest'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('unique_name=test\n');
  return directory;
}

@internal
final class ComposeCall {
  const ComposeCall(
    this.executable,
    this.arguments,
    this.workingDirectory,
    this.environment,
  );
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String>? environment;

  String get initScriptPath =>
      arguments[arguments.indexOf('--init-script') + 1];
  String get depsOutPath => environment!['XCROSS_DEPS_OUT']!;
}
