import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/compose/build/gradle_klib_builder.dart';
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/compose/toolchain/compose_host.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain.dart';

void main() {
  test(
    'build compiles nested module and dumps filtered ios dependencies',
    () async {
      final fixture =
          _Fixture.create(moduleName: 'a:b', host: ComposeHost.linuxX64)
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
      final calls = <_Call>[];

      addTearDown(fixture.dispose);
      final result = await GradleKlibBuilder.withSeams(
        runChecked:
            (executable, arguments, {workingDirectory, environment}) async {
              calls.add(
                _Call(executable, arguments, workingDirectory, environment),
              );
              if (arguments.contains(':a:b:dumpIosDeps')) {
                final initScript = File(
                  arguments[arguments.indexOf('--init-script') + 1],
                );
                final source = initScript.readAsStringSync();
                expect(source, contains('if (name != "b") return@allprojects'));
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
          _Fixture.create(moduleName: 'app:shared', host: ComposeHost.linuxX64)
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
        _Fixture.create(moduleName: 'shared', host: ComposeHost.linuxX64)
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
    final fixture = _Fixture.create(
      moduleName: 'shared',
      host: ComposeHost.linuxX64,
    )..createModuleKlib();
    final calls = <_Call>[];
    addTearDown(fixture.dispose);

    await GradleKlibBuilder.withSeams(
      runChecked:
          (executable, arguments, {workingDirectory, environment}) async {
            calls.add(
              _Call(executable, arguments, workingDirectory, environment),
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
          _Fixture.create(moduleName: 'shared', host: ComposeHost.windowsX64)
            ..createWrapper()
            ..createModuleKlib();
      final calls = <_Call>[];
      addTearDown(fixture.dispose);

      await GradleKlibBuilder.withSeams(
        runChecked:
            (executable, arguments, {workingDirectory, environment}) async {
              calls.add(
                _Call(executable, arguments, workingDirectory, environment),
              );
              if (arguments.contains(':shared:dumpIosDeps')) {
                File(environment!['XCROSS_DEPS_OUT']!).writeAsStringSync('');
              }
            },
      ).build(project: fixture.project, toolchain: fixture.toolchain);

      expect(calls.first.executable, 'cmd.exe');
      expect(calls.first.arguments.take(3), [
        '/d',
        '/c',
        p.join(fixture.root, 'gradlew.bat'),
      ]);
      final path = calls.first.environment!['PATH']!;
      expect(path, startsWith('${p.join(fixture.javaHome, 'bin')};'));
    },
  );

  test('uses POSIX PATH separator for Linux hosts', () async {
    final fixture =
        _Fixture.create(moduleName: 'shared', host: ComposeHost.linuxX64)
          ..createWrapper()
          ..createModuleKlib();
    _Call? compile;
    addTearDown(fixture.dispose);

    await GradleKlibBuilder.withSeams(
      runChecked:
          (executable, arguments, {workingDirectory, environment}) async {
            compile ??= _Call(
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
      final fixture = _Fixture.create(
        moduleName: 'shared',
        host: ComposeHost.linuxX64,
      )..createWrapper();
      _Call? depsCall;
      addTearDown(fixture.dispose);

      await expectLater(
        GradleKlibBuilder.withSeams(
          runChecked:
              (executable, arguments, {workingDirectory, environment}) async {
                if (arguments.contains(':shared:dumpIosDeps')) {
                  depsCall = _Call(
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
          _Fixture.create(moduleName: 'shared', host: ComposeHost.linuxX64)
            ..createWrapper()
            ..createModuleKlib();
      _Call? depsCall;
      addTearDown(fixture.dispose);

      await expectLater(
        GradleKlibBuilder.withSeams(
          runChecked:
              (executable, arguments, {workingDirectory, environment}) async {
                if (arguments.contains(':shared:dumpIosDeps')) {
                  depsCall = _Call(
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
      final fixture = _Fixture.create(
        moduleName: 'shared',
        host: ComposeHost.linuxX64,
      )..createWrapper();
      String? depsOutPath;
      addTearDown(fixture.dispose);

      await expectLater(
        GradleKlibBuilder.withSeams(
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
      final fixture = _Fixture.create(
        moduleName: 'shared',
        host: ComposeHost.linuxX64,
      )..createWrapper();
      _Call? depsCall;
      addTearDown(fixture.dispose);

      await expectLater(
        GradleKlibBuilder.withSeams(
          runChecked:
              (executable, arguments, {workingDirectory, environment}) async {
                if (arguments.contains(':shared:dumpIosDeps')) {
                  depsCall = _Call(
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

final class _Fixture {
  _Fixture._(this.temp, this.root, this.moduleName, this.host)
    : modulePath = p.joinAll([root, ...moduleName.split(':')]),
      kotlinHome = p.join(root, 'kotlinc'),
      javaHome = p.join(root, 'jdk');

  static _Fixture create({
    required String moduleName,
    required ComposeHost host,
  }) {
    final temp = Directory.systemTemp.createTempSync(
      'xcross_gradle_builder_test_',
    );
    final fixture = _Fixture._(temp, temp.path, moduleName, host);
    Directory(fixture.modulePath).createSync(recursive: true);
    return fixture;
  }

  final Directory temp;
  final String root;
  final String moduleName;
  final ComposeHost host;
  final String modulePath;
  final String kotlinHome;
  final String javaHome;

  String get moduleLeaf => moduleName.split(':').last;
  String get moduleKlibPath => p.join(
    modulePath,
    'build',
    'classes',
    'kotlin',
    'iosArm64',
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

  void createWrapper() {
    File(
      p.join(root, host.isWindows ? 'gradlew.bat' : 'gradlew'),
    ).writeAsStringSync('');
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

  String get initScriptPath =>
      arguments[arguments.indexOf('--init-script') + 1];
  String get depsOutPath => environment!['XCROSS_DEPS_OUT']!;
}
