import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
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
          final resolver = ComposeToolchainResolver.withSeams(
            which:
                (
                  name, {
                  environment,
                  windows,
                  extraDirectories = const [],
                }) async => switch (name) {
                  'java' => p.join(javaHome, 'bin', 'java.exe'),
                  'swiftc' => p.join(home.path, 'swiftc.exe'),
                  'clang' => p.join(home.path, 'clang.exe'),
                  _ => null,
                },
            run:
                (
                  executable,
                  arguments, {
                  workingDirectory,
                  environment,
                }) async =>
                    executable.endsWith('java.exe') &&
                        arguments.contains('-version')
                    ? const ComposeProcessResult(
                        0,
                        '',
                        'openjdk version "21.0.2"',
                      )
                    : const ComposeProcessResult(0, '', ''),
            currentDarwinSdk: (_) => sdk,
            resolveLd64Lld: (_, {runProcess}) async =>
                p.join(home.path, 'ld64.lld.exe'),
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
          expect(toolchain.ld64Lld, endsWith('ld64.lld.exe'));
          expect(toolchain.darwinSdkPath, '/sdk');
        } finally {
          project.deleteSync(recursive: true);
          home.deleteSync(recursive: true);
        }
      },
    );
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
      'downloads host and overlay archives, copies iOS overlay, patches jars, warms dependencies, and installs atomically',
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
              if (p.basename(archive.path).contains('macos')) {
                File(
                    p.join(
                      dest.path,
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
                      dest.path,
                      'klib',
                      'platform',
                      'ios_arm64',
                      'platform.txt',
                    ),
                  )
                  ..createSync(recursive: true)
                  ..writeAsStringSync('platform');
              } else {
                File(p.join(dest.path, 'bin', 'konanc.bat'))
                  ..createSync(recursive: true)
                  ..writeAsStringSync('konanc');
                File(
                    p.join(
                      dest.path,
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
            '-version',
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
  });
}

final class FakeDarwinSdk {
  FakeDarwinSdk(this.swiftSdkPath);

  final String swiftSdkPath;
}
