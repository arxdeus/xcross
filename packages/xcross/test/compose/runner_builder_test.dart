import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/compose/compose.dart';
import 'package:xcross/src/errors.dart';

void main() {
  test(
    'ObjC runner imports UIKit and framework and links exact iOS runner inputs',
    () async {
      final fixture = _Fixture.create()..createSdk();
      final calls = <_Call>[];
      addTearDown(fixture.dispose);

      final output =
          await ObjcRunnerBuilder.withSeams(
            runChecked: (executable, arguments, {workingDirectory}) async {
              calls.add(_Call(executable, arguments, workingDirectory));
              if (executable == fixture.toolchain.clang) {
                File(
                  p.join(fixture.objcBuildDir, 'main.o'),
                ).writeAsStringSync('object');
              } else if (executable == fixture.toolchain.ld64Lld) {
                fixture.writeMachO(p.join(fixture.objcBuildDir, 'Runner'));
              }
            },
          ).build(
            project: fixture.objcProject,
            frameworkPath: fixture.frameworkPath,
            toolchain: fixture.toolchain,
          );

      expect(output, p.join(fixture.objcBuildDir, 'Runner'));
      expect(calls, hasLength(2));
      final mainSource = File(
        p.join(fixture.root, 'build', 'xcross-compose', 'Runner', 'main.m'),
      ).readAsStringSync();
      expect(mainSource, contains('#import <UIKit/UIKit.h>'));
      expect(mainSource, contains('#import <Shared/Shared.h>'));
      expect(
        mainSource,
        contains('[SharedMainViewControllerKt MainViewController]'),
      );
      expect(mainSource, contains('UIApplicationMain'));

      expect(calls.first.executable, fixture.toolchain.clang);
      expect(calls.first.workingDirectory, fixture.root);
      expect(
        calls.first.arguments,
        containsAllInOrder(['-target', 'arm64-apple-ios15.0']),
      );
      expect(
        calls.first.arguments,
        containsAllInOrder(['-isysroot', fixture.iphoneSdk]),
      );
      expect(
        calls.first.arguments,
        containsAllInOrder(['-F', p.dirname(fixture.frameworkPath)]),
      );
      expect(
        calls.first.arguments,
        containsAllInOrder(['-I', p.join(fixture.frameworkPath, 'Headers')]),
      );
      expect(
        calls.first.arguments,
        containsAllInOrder(['-miphoneos-version-min=15.0']),
      );

      expect(calls.last.executable, fixture.toolchain.ld64Lld);
      expect(calls.last.arguments, containsAllInOrder(['-arch', 'arm64']));
      expect(
        calls.last.arguments,
        containsAllInOrder(['-platform_version', 'ios', '15.0', '26.5']),
      );
      expect(
        calls.last.arguments,
        containsAllInOrder(['-syslibroot', fixture.iphoneSdk]),
      );
      expect(
        calls.last.arguments,
        containsAllInOrder(['-framework', 'Shared']),
      );
      expect(calls.last.arguments, containsAllInOrder(['-framework', 'UIKit']));
      expect(
        calls.last.arguments,
        containsAllInOrder(['-rpath', '@executable_path/Frameworks']),
      );
    },
  );

  test(
    'Swift runner compiles all detected sources with resource dir, linker, framework search, and rpath',
    () async {
      final fixture = _Fixture.create()..createSdk();
      final calls = <_Call>[];
      addTearDown(fixture.dispose);

      final output =
          await SwiftRunnerBuilder.withSeams(
            runChecked: (executable, arguments, {workingDirectory}) async {
              calls.add(_Call(executable, arguments, workingDirectory));
              fixture.writeMachO(
                p.join(fixture.root, 'build', 'xcross-compose', 'Runner'),
              );
            },
          ).build(
            project: fixture.swiftProject,
            frameworkPath: fixture.frameworkPath,
            toolchain: fixture.toolchain,
          );

      expect(output, p.join(fixture.root, 'build', 'xcross-compose', 'Runner'));
      expect(calls, hasLength(1));
      expect(calls.single.executable, fixture.toolchain.swiftc);
      expect(calls.single.workingDirectory, fixture.root);
      expect(
        calls.single.arguments,
        containsAllInOrder(['-sdk', fixture.iphoneSdk]),
      );
      expect(
        calls.single.arguments,
        containsAllInOrder(['-target', 'arm64-apple-ios15.0']),
      );
      expect(
        calls.single.arguments,
        containsAllInOrder(['-resource-dir', fixture.resourceDir]),
      );
      expect(
        calls.single.arguments,
        containsAllInOrder(['-F', p.dirname(fixture.frameworkPath)]),
      );
      expect(
        calls.single.arguments,
        containsAllInOrder(['-framework', 'Shared']),
      );
      expect(calls.single.arguments, contains('-parse-as-library'));
      expect(
        calls.single.arguments,
        contains('-use-ld=${fixture.toolchain.ld64Lld}'),
      );
      expect(
        calls.single.arguments,
        containsAllInOrder([
          '-Xlinker',
          '-rpath',
          '-Xlinker',
          '@executable_path/Frameworks',
        ]),
      );
      expect(
        calls.single.arguments,
        containsAll(fixture.swiftProject.swiftSources),
      );
    },
  );

  test(
    'rejects missing inputs and non Mach-O runner output without invoking file',
    () async {
      final fixture = _Fixture.create()..createSdk();
      addTearDown(fixture.dispose);

      await expectLater(
        ObjcRunnerBuilder().build(
          project: fixture.objcProject,
          frameworkPath: p.join(fixture.root, 'missing.framework'),
          toolchain: fixture.toolchain,
        ),
        throwsA(isA<XcrossError>()),
      );

      await expectLater(
        SwiftRunnerBuilder.withSeams(
          runChecked: (executable, arguments, {workingDirectory}) async {
            File(p.join(fixture.root, 'build', 'xcross-compose', 'Runner'))
              ..createSync(recursive: true)
              ..writeAsStringSync('not macho');
          },
        ).build(
          project: fixture.swiftProject,
          frameworkPath: fixture.frameworkPath,
          toolchain: fixture.toolchain,
        ),
        throwsA(isA<XcrossError>()),
      );
    },
  );

  for (final invalid in _invalidMachOOutputs) {
    test('ObjC runner rejects ${invalid.name} Mach-O output', () async {
      final fixture = _Fixture.create()..createSdk();
      addTearDown(fixture.dispose);

      await expectLater(
        ObjcRunnerBuilder.withSeams(
          runChecked: (executable, arguments, {workingDirectory}) async {
            if (executable == fixture.toolchain.clang) {
              File(p.join(fixture.objcBuildDir, 'main.o'))
                ..createSync(recursive: true)
                ..writeAsStringSync('object');
            } else {
              fixture.writeBytes(
                p.join(fixture.objcBuildDir, 'Runner'),
                invalid.bytes,
              );
            }
          },
        ).build(
          project: fixture.objcProject,
          frameworkPath: fixture.frameworkPath,
          toolchain: fixture.toolchain,
        ),
        throwsA(isA<XcrossError>()),
      );
    });

    test('Swift runner rejects ${invalid.name} Mach-O output', () async {
      final fixture = _Fixture.create()..createSdk();
      addTearDown(fixture.dispose);

      await expectLater(
        SwiftRunnerBuilder.withSeams(
          runChecked: (executable, arguments, {workingDirectory}) async {
            fixture.writeBytes(
              p.join(fixture.root, 'build', 'xcross-compose', 'Runner'),
              invalid.bytes,
            );
          },
        ).build(
          project: fixture.swiftProject,
          frameworkPath: fixture.frameworkPath,
          toolchain: fixture.toolchain,
        ),
        throwsA(isA<XcrossError>()),
      );
    });
  }
}

const _invalidMachOOutputs = <_InvalidMachOOutput>[
  _InvalidMachOOutput('empty', []),
  _InvalidMachOOutput('4-byte', [0xfe, 0xed, 0xfa, 0xcf]),
  _InvalidMachOOutput('truncated-header', [
    0xfe,
    0xed,
    0xfa,
    0xcf,
    0,
    0,
    0,
    12,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    2,
  ]),
  _InvalidMachOOutput('wrong-endian', [
    0xcf,
    0xfa,
    0xed,
    0xfe,
    0,
    0,
    0,
    12,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    2,
    0,
    0,
    0,
    2,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  ]),
];

final class _InvalidMachOOutput {
  const _InvalidMachOOutput(this.name, this.bytes);

  final String name;
  final List<int> bytes;
}

final class _Fixture {
  _Fixture._(this.temp)
    : root = temp.path,
      frameworkPath = p.join(temp.path, 'Shared.framework');

  factory _Fixture.create() => _Fixture._(
    Directory.systemTemp.createTempSync('xcross_runner_builder_test_'),
  );

  final Directory temp;
  final String root;
  final String frameworkPath;

  String get iphoneSdk => p.join(
    root,
    'DarwinSDK',
    'Developer',
    'Platforms',
    'iPhoneOS.platform',
    'Developer',
    'SDKs',
    'iPhoneOS.sdk',
  );
  String get resourceDir => p.join(
    root,
    'DarwinSDK',
    'Developer',
    'Toolchains',
    'XcodeDefault.xctoolchain',
    'usr',
    'lib',
    'swift',
  );
  String get objcBuildDir => p.join(root, 'iosApp', '.build', 'runner');

  ComposeToolchain get toolchain => ComposeToolchain(
    host: ComposeHost.linuxX64,
    kotlinHome: p.join(root, 'kotlin'),
    konanCache: p.join(root, 'konan-cache'),
    konancExecutable: p.join(root, 'kotlin', 'bin', 'konanc'),
    javaHome: p.join(root, 'jdk'),
    javaExecutable: p.join(root, 'jdk', 'bin', 'java'),
    gradleExecutable: 'gradle',
    swiftc: p.join(root, 'swiftc'),
    clang: p.join(root, 'clang'),
    ld64Lld: p.join(root, 'ld64.lld'),
    darwinSdkPath: p.join(root, 'DarwinSDK'),
  );

  KmpProject get objcProject => KmpProject(
    root: root,
    modulePath: p.join(root, 'shared'),
    moduleName: 'shared',
    baseName: 'Shared',
    entryKind: KmpEntryKind.runnableApp,
    bundleId: 'dev.example.shared',
    appName: 'Example',
    entryClass: 'MainViewControllerKt',
    entrySelector: 'MainViewController',
  );

  KmpProject get swiftProject => KmpProject(
    root: root,
    modulePath: p.join(root, 'shared'),
    moduleName: 'shared',
    baseName: 'Shared',
    entryKind: KmpEntryKind.swiftApp,
    bundleId: 'dev.example.shared',
    appName: 'Example',
    swiftAppDir: p.join(root, 'iosApp'),
    swiftSources: [
      p.join(root, 'iosApp', 'App.swift'),
      p.join(root, 'iosApp', 'ContentView.swift'),
    ],
  );

  void createSdk() {
    Directory(p.join(frameworkPath, 'Headers')).createSync(recursive: true);
    File(p.join(frameworkPath, 'Shared')).writeAsStringSync('framework');
    File(
      p.join(frameworkPath, 'Headers', 'Shared.h'),
    ).writeAsStringSync('header');
    Directory(
      p.join(iphoneSdk, 'System', 'Library', 'Frameworks'),
    ).createSync(recursive: true);
    Directory(
      p.join(iphoneSdk, 'System', 'Library', 'SubFrameworks'),
    ).createSync(recursive: true);
    Directory(
      p.join(resourceDir, 'clang', 'include'),
    ).createSync(recursive: true);
    File(
      p.join(resourceDir, 'clang', 'include', 'stdarg.h'),
    ).writeAsStringSync('');
    for (final source in swiftProject.swiftSources) {
      File(source)
        ..createSync(recursive: true)
        ..writeAsStringSync('import SwiftUI');
    }
  }

  void writeMachO(String path) {
    final bytes = Uint8List(32)..buffer.asByteData().setUint32(0, 0xfeedfacf);
    writeBytes(path, bytes);
  }

  void writeBytes(String path, List<int> bytes) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
  }

  Future<void> dispose() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  }
}

final class _Call {
  const _Call(this.executable, this.arguments, this.workingDirectory);
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
}
