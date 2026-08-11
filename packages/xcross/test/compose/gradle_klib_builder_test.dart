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
      final temp = await Directory.systemTemp.createTemp(
        'xcross_gradle_builder_test_',
      );
      addTearDown(() async {
        if (temp.existsSync()) await temp.delete(recursive: true);
      });
      final root = temp.path;
      final module = Directory(p.join(root, 'a', 'b'))
        ..createSync(recursive: true);
      File(p.join(root, 'gradlew')).writeAsStringSync('');
      final moduleKlib = Directory(
        p.join(
          module.path,
          'build',
          'classes',
          'kotlin',
          'iosArm64',
          'main',
          'klib',
          'b',
        ),
      )..createSync(recursive: true);
      final externalKlib = Directory(p.join(root, 'external', 'compose.klib'))
        ..createSync(recursive: true);
      final kotlinHome = p.join(root, 'kotlinc');
      final platformKlib = Directory(
        p.join(kotlinHome, 'klib', 'platform', 'ios_arm64', 'UIKit.klib'),
      )..createSync(recursive: true);
      final calls = <_Call>[];

      final builder = GradleKlibBuilder.withSeams(
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
                expect(source, contains('System.getenv("XCROSS_DEPS_OUT")'));
                final out = environment!['XCROSS_DEPS_OUT']!;
                File(out).writeAsStringSync(
                  [
                    externalKlib.path,
                    platformKlib.path,
                    p.join(root, 'missing.klib'),
                    p.join(root, 'not-klib.jar'),
                  ].join('\n'),
                );
              }
            },
      );

      final result = await builder.build(
        project: KmpProject(
          root: root,
          modulePath: module.path,
          moduleName: 'a:b',
          baseName: 'Shared',
          entryKind: KmpEntryKind.frameworkOnly,
          bundleId: 'dev.example.app',
          appName: 'Example',
        ),
        toolchain: _toolchain(root, kotlinHome, ComposeHost.linuxX64),
      );

      expect(result.moduleKlibPath, moduleKlib.path);
      expect(result.dependencies, [externalKlib.path]);
      expect(calls, hasLength(2));
      expect(calls.first.executable, p.join(root, 'gradlew'));
      expect(calls.first.arguments, [
        ':a:b:compileKotlinIosArm64',
        '-Pkotlin.native.enableKlibsCrossCompilation=true',
        '--no-daemon',
        '--console=plain',
      ]);
      expect(calls[1].arguments.first, ':a:b:dumpIosDeps');
      expect(calls[1].arguments, contains('--no-configuration-cache'));
      expect(calls.every((call) => call.workingDirectory == root), isTrue);
      final initPath =
          calls[1].arguments[calls[1].arguments.indexOf('--init-script') + 1];
      expect(File(initPath).existsSync(), isFalse);
      expect(
        File(calls[1].environment!['XCROSS_DEPS_OUT']!).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'wraps Windows batch gradle wrapper with cmd.exe before system Gradle',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'xcross_gradle_builder_windows_test_',
      );
      addTearDown(() async {
        if (temp.existsSync()) await temp.delete(recursive: true);
      });
      final root = temp.path;
      final module = Directory(p.join(root, 'shared'))
        ..createSync(recursive: true);
      Directory(
        p.join(
          module.path,
          'build',
          'classes',
          'kotlin',
          'iosArm64',
          'main',
          'klib',
          'shared',
        ),
      ).createSync(recursive: true);
      File(p.join(root, 'gradlew.bat')).writeAsStringSync('');
      final calls = <_Call>[];
      final builder = GradleKlibBuilder.withSeams(
        runChecked:
            (executable, arguments, {workingDirectory, environment}) async {
              calls.add(
                _Call(executable, arguments, workingDirectory, environment),
              );
              if (arguments.contains(':shared:dumpIosDeps')) {
                File(environment!['XCROSS_DEPS_OUT']!).writeAsStringSync('');
              }
            },
      );

      await builder.build(
        project: KmpProject(
          root: root,
          modulePath: module.path,
          moduleName: 'shared',
          baseName: 'Shared',
          entryKind: KmpEntryKind.frameworkOnly,
          bundleId: 'dev.example.app',
          appName: 'Example',
        ),
        toolchain: _toolchain(
          root,
          p.join(root, 'kotlinc'),
          ComposeHost.windowsX64,
        ),
      );

      expect(calls.first.executable, 'cmd.exe');
      expect(calls.first.arguments.take(3), [
        '/d',
        '/c',
        p.join(root, 'gradlew.bat'),
      ]);
    },
  );
}

ComposeToolchain _toolchain(String root, String kotlinHome, ComposeHost host) =>
    ComposeToolchain(
      host: host,
      kotlinHome: kotlinHome,
      konanCache: p.join(root, 'konan-cache'),
      konancExecutable: p.join(
        kotlinHome,
        'bin',
        host.isWindows ? 'konanc.bat' : 'konanc',
      ),
      javaHome: p.join(root, 'jdk'),
      javaExecutable: p.join(
        root,
        'jdk',
        'bin',
        host.isWindows ? 'java.exe' : 'java',
      ),
      gradleExecutable: host.isWindows ? 'gradle.bat' : 'gradle',
      swiftc: p.join(root, 'swiftc'),
      clang: p.join(root, 'clang'),
      ld64Lld: p.join(root, 'ld64.lld'),
      darwinSdkPath: p.join(root, 'sdk'),
    );

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
