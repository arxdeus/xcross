@TestOn('!windows')
library;

import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/compose/build/objc_runner_builder.dart';
import 'package:xcross/src/shared/compose/build/swift_runner_builder.dart';
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/target/shared/compose/compose_target.dart';

import 'support/compose_platforms.dart';

void main() {
  late ComposeTestSession session;
  setUp(() {
    session = createComposeTestSession();
  });
  tearDown(() => session.dispose());
  test(
    'ObjC and Swift runners use simulator triples SDK linker and runtime',
    () async {
      final fixture =
          ComposeFixture.create(
              session,
              session.fixtureSimulatorTarget,
              sdkVersion: '26.5',
            )
            ..createSdk()
            ..createCompilerRt();
      addTearDown(fixture.dispose);
      final objc = <ComposeCall>[];
      await ObjcRunnerBuilder.withSeams(
        fixture.toolchain.runner,
        runChecked: (executable, arguments, {workingDirectory}) async {
          objc.add(ComposeCall(executable, arguments, workingDirectory));
          fixture.writeMachO(arguments[arguments.indexOf('-o') + 1]);
        },
      ).build(
        project: fixture.objcProject,
        frameworkPath: fixture.frameworkPath,
        toolchain: fixture.toolchain,
      );
      expect(
        objc.first.arguments,
        containsAllInOrder(['-target', 'arm64-apple-ios15.0-simulator']),
      );
      expect(
        objc.first.arguments,
        contains('-mios-simulator-version-min=15.0'),
      );
      expect(objc.first.arguments, contains(fixture.iphoneSdk));
      expect(
        objc.last.arguments,
        containsAllInOrder([
          '-platform_version',
          'ios-simulator',
          '15.0',
          '26.5',
        ]),
      );
      expect(objc.last.arguments, contains(fixture.compilerRtIosPath));
      expect(
        objc.last.arguments,
        contains(p.join(fixture.objcBuildDir, 'Runner')),
      );
      final swift = <ComposeCall>[];
      final output =
          await SwiftRunnerBuilder.withSeams(
            fixture.toolchain.runner,
            runChecked: (executable, arguments, {workingDirectory}) async {
              swift.add(ComposeCall(executable, arguments, workingDirectory));
              fixture.writeMachO(arguments[arguments.indexOf('-o') + 1]);
            },
          ).build(
            project: fixture.swiftProject,
            frameworkPath: fixture.frameworkPath,
            toolchain: fixture.toolchain,
          );
      expect(
        output,
        p.join(
          fixture.root,
          'build',
          'xcross-ios-simulator',
          'swift-runner',
          'Runner',
        ),
      );
      expect(
        swift.single.arguments,
        containsAllInOrder(['-target', 'arm64-apple-ios15.0-simulator']),
      );
      expect(
        swift.single.arguments,
        containsAllInOrder(['-sdk', fixture.iphoneSdk]),
      );
      expect(
        swift.single.arguments,
        containsAllInOrder(['-platform_version', '-Xlinker', 'ios-simulator']),
      );
      expect(swift.single.arguments, contains(fixture.compilerRtIosPath));
    },
  );

  test(
    'ObjC runner imports UIKit and framework and links exact iOS runner inputs',
    () async {
      final fixture = ComposeFixture.create(
        session,
        session.fixtureIPhoneTarget,
      )..createSdk();
      final calls = <ComposeCall>[];
      addTearDown(fixture.dispose);

      final output =
          await ObjcRunnerBuilder.withSeams(
            fixture.toolchain.runner,
            runChecked: (executable, arguments, {workingDirectory}) async {
              calls.add(ComposeCall(executable, arguments, workingDirectory));
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
      // A transparent Compose layer over a colourless UIWindow renders as a
      // black screen on device, so the runner must colour the window.
      expect(
        mainSource,
        contains(
          'self.window.backgroundColor = [UIColor systemBackgroundColor];',
        ),
      );

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
      expect(calls.last.arguments, contains('-dead_strip'));
      expect(
        calls.last.arguments,
        containsAllInOrder(['-rpath', '@executable_path/Frameworks']),
      );
    },
  );

  test(
    'Swift runner compiles all detected sources with resource dir, linker, framework search, and rpath',
    () async {
      final fixture = ComposeFixture.create(
        session,
        session.fixtureIPhoneTarget,
      )..createSdk();
      final calls = <ComposeCall>[];
      addTearDown(fixture.dispose);

      final output =
          await SwiftRunnerBuilder.withSeams(
            fixture.toolchain.runner,
            runChecked: (executable, arguments, {workingDirectory}) async {
              calls.add(ComposeCall(executable, arguments, workingDirectory));
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
          '-arch',
          '-Xlinker',
          'arm64',
          '-Xlinker',
          '-platform_version',
          '-Xlinker',
          'ios',
          '-Xlinker',
          '15.0',
          '-Xlinker',
          '26.5',
        ]),
      );
      expect(calls.single.arguments, contains('-dead_strip'));
      expect(
        calls.single.arguments[calls.single.arguments.indexOf('-dead_strip') -
            1],
        '-Xlinker',
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
      // No .../lib/clang/<version>/lib/darwin/libclang_rt.ios.a exists
      // under this fixture's darwinSdkBundle (createSdk() never calls
      // createCompilerRt()), so _compilerRtIos must find nothing and the
      // build must not fail or inject a bogus path.
      expect(calls.single.arguments, isNot(contains('libclang_rt.ios.a')));
      expect(
        calls.single.arguments,
        containsAll(fixture.swiftProject.swiftSources),
      );
    },
  );

  test('Swift runner links the real compiler-rt static library when the '
      'Darwin SDK bundle has one', () async {
    // A non-Apple clang driving the swiftc link (Ubuntu's packaged clang,
    // the Windows swift.org LLVM's clang) doesn't auto-link
    // libclang_rt.ios.a the way Apple's own clang does, and the link then
    // fails with "undefined symbol: ___isPlatformVersionAtLeast" (a
    // symbol libclang_rt.ios.a provides). Confirm the builder passes it
    // explicitly via -Xlinker when the Darwin SDK bundle has one staged.
    final fixture = ComposeFixture.create(session, session.fixtureIPhoneTarget)
      ..createSdk()
      ..createCompilerRt();
    final calls = <ComposeCall>[];
    addTearDown(fixture.dispose);

    await SwiftRunnerBuilder.withSeams(
      fixture.toolchain.runner,
      runChecked: (executable, arguments, {workingDirectory}) async {
        calls.add(ComposeCall(executable, arguments, workingDirectory));
        fixture.writeMachO(
          p.join(fixture.root, 'build', 'xcross-compose', 'Runner'),
        );
      },
    ).build(
      project: fixture.swiftProject,
      frameworkPath: fixture.frameworkPath,
      toolchain: fixture.toolchain,
    );

    expect(
      calls.single.arguments,
      containsAllInOrder(['-Xlinker', fixture.compilerRtIosPath]),
    );
  });

  test(
    'Swift runner picks the newest clang version directory deterministically '
    'when multiple exist',
    () async {
      // _compilerRtIos sorts candidate version directories rather than
      // trusting Directory.listSync()'s filesystem-dependent order, so this
      // must pick "21" over "19" regardless of listing order. Mirrors the
      // matching konan_configuration_test.dart test for
      // _findCompilerRtDarwinDir.
      final fixture =
          ComposeFixture.create(session, session.fixtureIPhoneTarget)
            ..createSdk()
            ..createCompilerRt();
      final olderDir = p.join(
        fixture.darwinSdkBundle,
        'Developer',
        'Toolchains',
        'XcodeDefault.xctoolchain',
        'usr',
        'lib',
        'clang',
        '19',
        'lib',
        'darwin',
      );
      Directory(olderDir).createSync(recursive: true);
      File(
        p.join(olderDir, 'libclang_rt.ios.a'),
      ).writeAsStringSync('WRONG-should-not-be-picked');
      final calls = <ComposeCall>[];
      addTearDown(fixture.dispose);

      await SwiftRunnerBuilder.withSeams(
        fixture.toolchain.runner,
        runChecked: (executable, arguments, {workingDirectory}) async {
          calls.add(ComposeCall(executable, arguments, workingDirectory));
          fixture.writeMachO(
            p.join(fixture.root, 'build', 'xcross-compose', 'Runner'),
          );
        },
      ).build(
        project: fixture.swiftProject,
        frameworkPath: fixture.frameworkPath,
        toolchain: fixture.toolchain,
      );

      expect(
        calls.single.arguments,
        containsAllInOrder(['-Xlinker', fixture.compilerRtIosPath]),
      );
    },
  );

  test(
    'rejects missing inputs and non Mach-O runner output without invoking file',
    () async {
      final fixture = ComposeFixture.create(
        session,
        session.fixtureIPhoneTarget,
      )..createSdk();
      addTearDown(fixture.dispose);

      await expectLater(
        ObjcRunnerBuilder(fixture.toolchain.runner).build(
          project: fixture.objcProject,
          frameworkPath: p.join(fixture.root, 'missing.framework'),
          toolchain: fixture.toolchain,
        ),
        throwsA(isA<XcrossError>()),
      );

      await expectLater(
        SwiftRunnerBuilder.withSeams(
          fixture.toolchain.runner,
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

  for (final valid in _validMachOOutputs) {
    test('ObjC runner accepts ${valid.name} 64-bit Mach-O magic', () async {
      final fixture = ComposeFixture.create(
        session,
        session.fixtureIPhoneTarget,
      )..createSdk();
      addTearDown(fixture.dispose);

      final output =
          await ObjcRunnerBuilder.withSeams(
            fixture.toolchain.runner,
            runChecked: (executable, arguments, {workingDirectory}) async {
              if (executable == fixture.toolchain.clang) {
                File(p.join(fixture.objcBuildDir, 'main.o'))
                  ..createSync(recursive: true)
                  ..writeAsStringSync('object');
              } else {
                fixture.writeBytes(
                  p.join(fixture.objcBuildDir, 'Runner'),
                  valid.bytes,
                );
              }
            },
          ).build(
            project: fixture.objcProject,
            frameworkPath: fixture.frameworkPath,
            toolchain: fixture.toolchain,
          );

      expect(output, p.join(fixture.objcBuildDir, 'Runner'));
    });

    test('Swift runner accepts ${valid.name} 64-bit Mach-O magic', () async {
      final fixture = ComposeFixture.create(
        session,
        session.fixtureIPhoneTarget,
      )..createSdk();
      addTearDown(fixture.dispose);

      final output =
          await SwiftRunnerBuilder.withSeams(
            fixture.toolchain.runner,
            runChecked: (executable, arguments, {workingDirectory}) async {
              fixture.writeBytes(
                p.join(fixture.root, 'build', 'xcross-compose', 'Runner'),
                valid.bytes,
              );
            },
          ).build(
            project: fixture.swiftProject,
            frameworkPath: fixture.frameworkPath,
            toolchain: fixture.toolchain,
          );

      expect(output, p.join(fixture.root, 'build', 'xcross-compose', 'Runner'));
    });
  }

  for (final invalid in _invalidMachOOutputs) {
    test('ObjC runner rejects ${invalid.name} Mach-O output', () async {
      final fixture = ComposeFixture.create(
        session,
        session.fixtureIPhoneTarget,
      )..createSdk();
      addTearDown(fixture.dispose);

      await expectLater(
        ObjcRunnerBuilder.withSeams(
          fixture.toolchain.runner,
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
      final fixture = ComposeFixture.create(
        session,
        session.fixtureIPhoneTarget,
      )..createSdk();
      addTearDown(fixture.dispose);

      await expectLater(
        SwiftRunnerBuilder.withSeams(
          fixture.toolchain.runner,
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

final _validMachOOutputs = <MachOOutput>[
  MachOOutput('little-endian', _machoBytes([0xcf, 0xfa, 0xed, 0xfe])),
  MachOOutput('big-endian', _machoBytes([0xfe, 0xed, 0xfa, 0xcf])),
];

final _invalidMachOOutputs = <MachOOutput>[
  const MachOOutput('empty', []),
  const MachOOutput('4-byte', [0xfe, 0xed, 0xfa, 0xcf]),
  const MachOOutput('truncated-header', [
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
  MachOOutput('reversed-32-bit-magic', _machoBytes([0xce, 0xfa, 0xed, 0xfe])),
  const MachOOutput('invalid-magic', [
    0xca,
    0xfe,
    0xba,
    0xbe,
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

List<int> _machoBytes(List<int> magic) => [
  ...magic,
  ...List<int>.filled(28, 0),
];

@internal
final class MachOOutput {
  const MachOOutput(this.name, this.bytes);

  final String name;
  final List<int> bytes;
}

@internal
final class ComposeFixture {
  ComposeFixture._(this.session, this.temp, this.target, this.sdkVersion)
    : root = temp.path,
      frameworkPath = p.join(temp.path, 'Shared.framework');

  factory ComposeFixture.create(
    ComposeTestSession session,
    ComposeTarget<PlatformHostInterface> target, {
    String sdkVersion = '',
  }) => ComposeFixture._(
    session,
    Directory.systemTemp.createTempSync('xcross_runner_builder_test_'),
    target,
    sdkVersion,
  );
  final ComposeTestSession session;

  final Directory temp;
  final ComposeTarget<PlatformHostInterface> target;
  final String sdkVersion;
  final String root;
  final String frameworkPath;

  String get iphoneSdk => p.join(
    root,
    'DarwinSDK',
    'Developer',
    'Platforms',
    '${target.buildPlatform.platformName}.platform',
    'Developer',
    'SDKs',
    '${target.buildPlatform.platformName}$sdkVersion.sdk',
  );
  String get darwinSdkBundle => p.join(root, 'DarwinSDK');
  String get resourceDir => p.join(
    darwinSdkBundle,
    'Developer',
    'Toolchains',
    'XcodeDefault.xctoolchain',
    'usr',
    'lib',
    'swift',
  );
  String get objcBuildDir => target.runnerDirectory(root, 'objc');

  /// Where `_compilerRtIos` looks for `libclang_rt.ios.a`, mirroring the
  /// real `.../XcodeDefault.xctoolchain/usr/lib/clang/<version>/lib/darwin/`
  /// layout under a versioned clang subdirectory.
  String get compilerRtIosPath => p.join(
    darwinSdkBundle,
    'Developer',
    'Toolchains',
    'XcodeDefault.xctoolchain',
    'usr',
    'lib',
    'clang',
    '21',
    'lib',
    'darwin',
    target.compilerRtName,
  );

  ComposeToolchain get toolchain => ComposeToolchain(
    log: session.fixtureLog,
    target: target,
    runner: ProcessRunner(
      log: session.fixtureLog,
      target.host,
      stdinStream: const Stream<List<int>>.empty(),
      stdoutSink: session.stdoutSink,
      stderrSink: session.stderrSink,
    ),
    kotlinHome: p.join(root, 'kotlin'),
    konanCache: p.join(root, 'konan-cache'),
    konancExecutable: p.join(root, 'kotlin', 'bin', 'konanc'),
    javaHome: p.join(root, 'jdk'),
    javaExecutable: p.join(root, 'jdk', 'bin', 'java'),
    gradleExecutable: 'gradle',
    swiftc: p.join(root, 'swiftc'),
    clang: p.join(root, 'clang'),
    ld64Lld: p.join(root, 'ld64.lld'),
    darwinSdkPath: iphoneSdk,
    darwinSdkBundle: darwinSdkBundle,
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

  void createCompilerRt() {
    Directory(p.dirname(compilerRtIosPath)).createSync(recursive: true);
    File(compilerRtIosPath).writeAsStringSync('fake-compiler-rt');
  }

  void writeMachO(String path) {
    writeBytes(path, _machoBytes([0xfe, 0xed, 0xfa, 0xcf]));
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

@internal
final class ComposeCall {
  const ComposeCall(this.executable, this.arguments, this.workingDirectory);
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
}
