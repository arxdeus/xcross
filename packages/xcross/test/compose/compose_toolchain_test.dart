import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/compose/compose.dart' as compose;
import 'package:xcross/src/compose/toolchain/archive_extractor.dart';
import 'package:xcross/src/compose/toolchain/compose_host.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain_installer.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain_resolver.dart';
import 'package:xcross/src/errors.dart';

void main() {
  group('ComposeSetupOptions.resolve', () {
    late Directory home;
    late Directory project;

    setUp(() {
      home = Directory.systemTemp.createTempSync('xcross-compose-home-');
      project = Directory.systemTemp.createTempSync('xcross-compose-project-');
    });

    tearDown(() {
      home.deleteSync(recursive: true);
      project.deleteSync(recursive: true);
    });

    test('uses KN_VERSION before project files and builds the cache path', () {
      File(p.join(project.path, 'gradle.properties'))
        ..createSync(recursive: true)
        ..writeAsStringSync('kotlin.version=1.9.0\n');

      final options = ComposeSetupOptions.resolve(
        env: {'HOME': home.path, 'KN_VERSION': '2.2.20'},
        projectRoot: project.path,
        host: ComposeHost.windowsX64,
      );

      expect(options.version, '2.2.20');
      expect(
        options.kotlinHome,
        p.join(
          home.path,
          '.konan',
          'kotlin-native-prebuilt-windows-x86_64-2.2.20',
        ),
      );
      expect(
        options.hostArchiveUrl,
        endsWith('/2.2.20/kotlin-native-prebuilt-2.2.20-windows-x86_64.zip'),
      );
      expect(
        options.overlayArchiveUrl,
        endsWith('/2.2.20/kotlin-native-prebuilt-2.2.20-macos-x86_64.tar.gz'),
      );
    });

    test(
      'falls back from Gradle version catalog to Gradle properties to default',
      () {
        final catalog =
            File(p.join(project.path, 'gradle', 'libs.versions.toml'))
              ..createSync(recursive: true)
              ..writeAsStringSync('kotlin = "2.2.10"\n');
        expect(
          ComposeSetupOptions.resolve(
            env: {'HOME': home.path},
            projectRoot: project.path,
            host: ComposeHost.linuxX64,
          ).version,
          '2.2.10',
        );

        catalog.deleteSync();
        File(
          p.join(project.path, 'gradle.properties'),
        ).writeAsStringSync('kotlin.version=2.1.21\n');
        expect(
          ComposeSetupOptions.resolve(
            env: {'HOME': home.path},
            projectRoot: project.path,
            host: ComposeHost.linuxX64,
          ).version,
          '2.1.21',
        );

        File(p.join(project.path, 'gradle.properties')).deleteSync();
        expect(
          ComposeSetupOptions.resolve(
            env: {'HOME': home.path},
            projectRoot: project.path,
            host: ComposeHost.linuxX64,
          ).version,
          ComposeSetupOptions.defaultKotlinNativeVersion,
        );
      },
    );
  });

  group('ComposeToolchainResolver', () {
    test('does not resolve when Kotlin/Native is not installed', () async {
      final project = Directory.systemTemp.createTempSync(
        'xcross-compose-project-',
      );
      final home = Directory.systemTemp.createTempSync('xcross-compose-home-');
      try {
        File(p.join(project.path, 'gradlew')).writeAsStringSync('#!/bin/sh');
        final javaHome = p.join(home.path, 'jdk-21');
        final sdk = FakeDarwinSdk('/sdk');
        final resolver = _resolverWithPreflight(
          javaHome: javaHome,
          sdk: sdk,
          home: home.path,
        );

        final toolchain = await resolver.resolve(
          host: ComposeHost.linuxX64,
          environment: {'HOME': home.path, 'JAVA_HOME': javaHome},
          projectRoot: project.path,
        );
        final problems = await resolver.problems(
          host: ComposeHost.linuxX64,
          environment: {'HOME': home.path, 'JAVA_HOME': javaHome},
          projectRoot: project.path,
        );

        expect(toolchain, isNull);
        expect(problems, contains(contains('Kotlin/Native compiler')));
      } finally {
        project.deleteSync(recursive: true);
        home.deleteSync(recursive: true);
      }
    });

    test(
      'reports actionable missing JDK, Gradle, Swift, clang, ld64.lld, and SDK problems',
      () async {
        final project = Directory.systemTemp.createTempSync(
          'xcross-compose-project-',
        );
        final home = Directory.systemTemp.createTempSync(
          'xcross-compose-home-',
        );
        try {
          final resolver = ComposeToolchainResolver.withSeams(
            which:
                (
                  _, {
                  environment,
                  windows,
                  extraDirectories = const [],
                }) async => null,
            currentDarwinSdk: (_) => null,
            resolveLd64Lld: (_, {runProcess}) async =>
                throw XcrossError('No ld64.lld that can link for iOS.'),
          );

          final problems = await resolver.problems(
            host: ComposeHost.linuxX64,
            environment: {'HOME': home.path},
            projectRoot: project.path,
          );

          expect(problems, contains(contains('JDK 21+')));
          expect(problems, contains(contains('Gradle wrapper or gradle')));
          expect(problems, contains(contains('swiftc')));
          expect(problems, contains(contains('clang')));
          expect(problems, contains(contains('ld64.lld')));
          expect(problems, contains(contains('Darwin SDK')));
        } finally {
          project.deleteSync(recursive: true);
          home.deleteSync(recursive: true);
        }
      },
    );

    test(
      'resolves JDK 21+, Gradle wrapper, Darwin tools, and Windows batch invocation',
      () async {
        final project = Directory.systemTemp.createTempSync(
          'xcross-compose-project-',
        );
        final home = Directory.systemTemp.createTempSync(
          'xcross-compose-home-',
        );
        try {
          final gradlew = File(p.join(project.path, 'gradlew.bat'))
            ..writeAsStringSync('@echo off');
          final javaHome = p.join(home.path, 'jdk-21');
          final sdk = FakeDarwinSdk('/sdk');
          final options = ComposeSetupOptions.resolve(
            env: {'HOME': home.path, 'JAVA_HOME': javaHome},
            projectRoot: project.path,
            host: ComposeHost.windowsX64,
          );
          Directory(
            p.join(options.kotlinHome, 'bin'),
          ).createSync(recursive: true);
          File(
            options.host.konancExecutable(options.kotlinHome),
          ).writeAsStringSync('konanc');
          final resolver = _resolverWithPreflight(
            javaHome: javaHome,
            sdk: sdk,
            home: home.path,
          );

          final toolchain = await resolver.resolve(
            host: ComposeHost.windowsX64,
            environment: {'HOME': home.path, 'JAVA_HOME': javaHome},
            projectRoot: project.path,
          );

          expect(toolchain, isNotNull);
          expect(toolchain!.javaHome, javaHome);
          expect(toolchain.gradleExecutable, gradlew.path);
          expect(toolchain.gradleInvocation, [
            'cmd.exe',
            '/d',
            '/c',
            gradlew.path,
          ]);
          expect(toolchain.swiftc, endsWith('swiftc.exe'));
          expect(toolchain.clang, endsWith('clang.exe'));
          expect(toolchain.ld64Lld, endsWith('ld64.lld'));
          expect(toolchain.darwinSdkPath, '/sdk');
        } finally {
          project.deleteSync(recursive: true);
          home.deleteSync(recursive: true);
        }
      },
    );

    test('ensure installs on a fresh cache and re-runs preflight', () async {
      final project = Directory.systemTemp.createTempSync(
        'xcross-compose-project-',
      );
      final home = Directory.systemTemp.createTempSync('xcross-compose-home-');
      var installs = 0;
      try {
        File(p.join(project.path, 'gradlew')).writeAsStringSync('#!/bin/sh');
        final javaHome = p.join(home.path, 'jdk-21');
        final sdk = FakeDarwinSdk('/sdk');
        final installer = ComposeToolchainInstaller.withSeams(
          downloadToFile: (_, _) async {},
          extractArchive: (_, _) async {},
          patchCompilerJar: (_) async {},
          runChecked: (_, __, {workingDirectory, environment}) async {},
          installRoot: (options, {required force}) async {
            installs++;
            Directory(
              p.join(options.kotlinHome, 'bin'),
            ).createSync(recursive: true);
            File(
              options.host.konancExecutable(options.kotlinHome),
            ).writeAsStringSync('konanc');
            return options.kotlinHome;
          },
        );
        final resolver = _resolverWithPreflight(
          javaHome: javaHome,
          sdk: sdk,
          home: home.path,
          installer: installer,
        );

        final toolchain = await resolver.ensure(
          host: ComposeHost.linuxX64,
          environment: {'HOME': home.path, 'JAVA_HOME': javaHome},
          projectRoot: project.path,
        );

        expect(installs, 1);
        expect(toolchain.konancExecutable, isA<String>());
        expect(File(toolchain.konancExecutable).existsSync(), isTrue);
      } finally {
        project.deleteSync(recursive: true);
        home.deleteSync(recursive: true);
      }
    });
  });

  group('ArchiveExtractor', () {
    test('rejects zip entries that escape the destination', () async {
      final archive = Archive()
        ..addFile(
          ArchiveFile('../escape.txt', 4, Uint8List.fromList('nope'.codeUnits)),
        );
      final bytes = ZipEncoder().encode(archive);
      final zip = File(
        p.join(
          Directory.systemTemp.createTempSync('xcross-archive-').path,
          'bad.zip',
        ),
      )..writeAsBytesSync(bytes);
      final dest = Directory.systemTemp.createTempSync('xcross-extract-');
      try {
        await expectLater(
          ArchiveExtractor.extractArchive(zip, dest),
          throwsA(
            isA<XcrossError>().having(
              (e) => e.message,
              'message',
              contains('escapes'),
            ),
          ),
        );
      } finally {
        zip.parent.deleteSync(recursive: true);
        dest.deleteSync(recursive: true);
      }
    });
  });

  group('ComposeToolchainInstaller', () {
    test(
      'uses cached fast path without download, extraction, process, or patch calls',
      () async {
        final home = Directory.systemTemp.createTempSync(
          'xcross-compose-home-',
        );
        final project = Directory.systemTemp.createTempSync(
          'xcross-compose-project-',
        );
        try {
          final options = ComposeSetupOptions.resolve(
            env: {'HOME': home.path, 'KN_VERSION': '2.2.20'},
            projectRoot: project.path,
            host: ComposeHost.linuxX64,
          );
          Directory(
            p.join(options.kotlinHome, 'bin'),
          ).createSync(recursive: true);
          File(
            options.host.konancExecutable(options.kotlinHome),
          ).writeAsStringSync('konanc');

          final installer = ComposeToolchainInstaller.withSeams(
            downloadToFile: (_, _) =>
                fail('download should not run on cached path'),
            extractArchive: (_, _) =>
                fail('extract should not run on cached path'),
            patchCompilerJar: (_) =>
                fail('patch should not run on cached path'),
            runChecked: (_, __, {workingDirectory, environment}) =>
                fail('warmup should not run on cached path'),
          );

          final installed = await installer.install(options: options);

          expect(installed, options.kotlinHome);
        } finally {
          home.deleteSync(recursive: true);
          project.deleteSync(recursive: true);
        }
      },
    );

    test(
      'normalizes upstream roots, overlays iOS files, patches jars, warms with a temporary hello world compile, and installs atomically',
      () async {
        final home = Directory.systemTemp.createTempSync(
          'xcross-compose-home-',
        );
        final project = Directory.systemTemp.createTempSync(
          'xcross-compose-project-',
        );
        final downloads = <String>[];
        final extracted = <String>[];
        final patched = <String>[];
        final commands = <List<String>>[];
        try {
          final options = ComposeSetupOptions.resolve(
            env: {'HOME': home.path, 'KN_VERSION': '2.2.20'},
            projectRoot: project.path,
            host: ComposeHost.windowsX64,
          );

          final installer = ComposeToolchainInstaller.withSeams(
            downloadToFile: (url, file) async {
              downloads.add(url);
              file.createSync(recursive: true);
              file.writeAsStringSync(p.basename(file.path));
            },
            extractArchive: (archive, dest) async {
              extracted.add(p.basename(archive.path));
              final root = Directory(
                p.join(
                  dest.path,
                  p.basename(archive.path).contains('macos')
                      ? 'kotlin-native-prebuilt-macos-x86_64-2.2.20'
                      : 'kotlin-native-prebuilt-windows-x86_64-2.2.20',
                ),
              );
              if (p.basename(archive.path).contains('macos')) {
                File(
                    p.join(
                      root.path,
                      'konan',
                      'targets',
                      'ios_arm64',
                      'target.txt',
                    ),
                  )
                  ..createSync(recursive: true)
                  ..writeAsStringSync('target');
                File(
                    p.join(
                      root.path,
                      'klib',
                      'platform',
                      'ios_arm64',
                      'platform.txt',
                    ),
                  )
                  ..createSync(recursive: true)
                  ..writeAsStringSync('platform');
              } else {
                File(p.join(root.path, 'bin', 'konanc.bat'))
                  ..createSync(recursive: true)
                  ..writeAsStringSync('konanc');
                File(
                    p.join(
                      root.path,
                      'lib',
                      'kotlin-native-compiler-embeddable.jar',
                    ),
                  )
                  ..createSync(recursive: true)
                  ..writeAsStringSync('jar');
              }
            },
            patchCompilerJar: (file) async => patched.add(file.path),
            runChecked:
                (
                  executable,
                  arguments, {
                  workingDirectory,
                  environment,
                }) async => commands.add([executable, ...arguments]),
          );

          final installed = await installer.install(
            options: options,
            force: true,
          );

          expect(installed, options.kotlinHome);
          expect(downloads, [
            options.hostArchiveUrl,
            options.overlayArchiveUrl,
          ]);
          expect(
            extracted,
            contains(options.host.hostArtifact(options.version)),
          );
          expect(
            extracted,
            contains(ComposeHost.macosX64OverlayArtifact(options.version)),
          );
          expect(
            File(
              p.join(
                options.kotlinHome,
                'konan',
                'targets',
                'ios_arm64',
                'target.txt',
              ),
            ).existsSync(),
            isTrue,
          );
          expect(
            File(
              p.join(
                options.kotlinHome,
                'klib',
                'platform',
                'ios_arm64',
                'platform.txt',
              ),
            ).existsSync(),
            isTrue,
          );
          expect(
            patched.single,
            endsWith('kotlin-native-compiler-embeddable.jar'),
          );
          expect(commands.single, [
            'cmd.exe',
            '/d',
            '/c',
            options.host.konancExecutable('${options.kotlinHome}.staging'),
            contains('hello.kt'),
            '-o',
            contains('hello'),
          ]);
          expect(
            Directory('${options.kotlinHome}.staging').existsSync(),
            isFalse,
          );
        } finally {
          home.deleteSync(recursive: true);
          project.deleteSync(recursive: true);
        }
      },
    );

    test(
      'warms POSIX hosts with a temporary hello world compile and cleans it',
      () async {
        final home = Directory.systemTemp.createTempSync(
          'xcross-compose-home-',
        );
        final project = Directory.systemTemp.createTempSync(
          'xcross-compose-project-',
        );
        final commands = <List<String>>[];
        String? warmDirectory;
        try {
          final options = ComposeSetupOptions.resolve(
            env: {'HOME': home.path, 'KN_VERSION': '2.2.20'},
            projectRoot: project.path,
            host: ComposeHost.linuxX64,
          );
          final installer = ComposeToolchainInstaller.withSeams(
            downloadToFile: (_, file) async =>
                file.writeAsStringSync('archive'),
            extractArchive: (archive, dest) async {
              final root = Directory(
                p.join(
                  dest.path,
                  p.basename(archive.path).contains('macos')
                      ? 'kotlin-native-prebuilt-macos-x86_64-2.2.20'
                      : 'kotlin-native-prebuilt-linux-x86_64-2.2.20',
                ),
              );
              if (p.basename(archive.path).contains('macos')) {
                File(p.join(root.path, 'konan', 'targets', 'ios_arm64', 't'))
                  ..createSync(recursive: true)
                  ..writeAsStringSync('t');
                File(p.join(root.path, 'klib', 'platform', 'ios_arm64', 'p'))
                  ..createSync(recursive: true)
                  ..writeAsStringSync('p');
              } else {
                File(p.join(root.path, 'bin', 'konanc'))
                  ..createSync(recursive: true)
                  ..writeAsStringSync('konanc');
              }
            },
            patchCompilerJar: (_) async {},
            runChecked:
                (executable, arguments, {workingDirectory, environment}) async {
                  commands.add([executable, ...arguments]);
                  warmDirectory = p.dirname(arguments.first);
                },
          );

          await installer.install(options: options, force: true);

          expect(
            commands.single.first,
            options.host.konancExecutable('${options.kotlinHome}.staging'),
          );
          expect(commands.single[1], endsWith('hello.kt'));
          expect(commands.single[2], '-o');
          expect(commands.single[3], contains('hello'));
          expect(Directory(warmDirectory!).existsSync(), isFalse);
        } finally {
          home.deleteSync(recursive: true);
          project.deleteSync(recursive: true);
        }
      },
    );
  });

  test('compose.dart exports Task 4 public APIs', () {
    expect(
      compose.ComposeHost.linuxX64.hostArtifact('2.2.20'),
      contains('linux-x86_64'),
    );
    expect(compose.ComposeToolchain, isNotNull);
    expect(compose.ComposeToolchainResolver.resolve, isA<Function>());
    expect(compose.ComposeSetupOptions.defaultKotlinNativeVersion, isNotEmpty);
    expect(compose.ComposeToolchainInstaller, isNotNull);
    expect(compose.ArchiveExtractor, isNotNull);
  });
}

InjectedComposeToolchainResolver _resolverWithPreflight({
  required String javaHome,
  required FakeDarwinSdk sdk,
  required String home,
  ComposeToolchainInstaller? installer,
}) => ComposeToolchainResolver.withSeams(
  which: (name, {environment, windows, extraDirectories = const []}) async =>
      switch (name) {
        'java' => p.join(
          javaHome,
          'bin',
          windows == true ? 'java.exe' : 'java',
        ),
        'swiftc' => p.join(home, windows == true ? 'swiftc.exe' : 'swiftc'),
        'clang' => p.join(home, windows == true ? 'clang.exe' : 'clang'),
        _ => null,
      },
  run: (executable, arguments, {workingDirectory, environment}) async =>
      executable.contains('java') && arguments.contains('-version')
      ? const ComposeProcessResult(0, '', 'openjdk version "21.0.2"')
      : const ComposeProcessResult(0, '', ''),
  currentDarwinSdk: (_) => sdk,
  resolveLd64Lld: (_, {runProcess}) async => p.join(home, 'ld64.lld'),
  installer: installer,
);

final class FakeDarwinSdk {
  FakeDarwinSdk(this.swiftSdkPath);

  final String swiftSdkPath;
}
