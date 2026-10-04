import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/linux/compose/linux_compose_host.dart';
import 'package:xcross/src/shared/compose/build/compose_pack_operation.dart';
import 'package:xcross/src/shared/compose/build/compose_packer.dart';
import 'package:xcross/src/shared/compose/build/gradle_klib_builder.dart';
import 'package:xcross/src/shared/compose/models/compose_build_options.dart';
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/models/pack_result.dart';
import 'package:xcross/src/target/shared/compose/compose_target.dart';

import 'support/compose_platforms.dart';

void main() {
  late ComposeTestSession session;
  setUp(() {
    session = createComposeTestSession();
  });
  tearDown(() => session.dispose());
  test(
    'cleanup uses the selected remapped filesystem, not ambient paths',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'compose-remapped-cleanup-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final files = RemappedComposeFileSystem(root.path);
      final host = LinuxHost(architecture: 'x64', fileSystem: files);
      final target = fixtureIPhoneTargetFor(LinuxComposeHost(host));
      final project = _project('/virtual-compose', KmpEntryKind.swiftApp);
      final app = files.directory('/virtual-compose/build/xcross-ios/Demo.app')
        ..createSync(recursive: true);
      final framework = files.directory(
        '/virtual-compose/build/xcross-ios/Shared.framework',
      )..createSync(recursive: true);
      files.requests.clear();
      final operation = ComposePackOperation.withSeams(
        target,
        runner: ProcessRunner(
          host,
          log: session.fixtureLog,
          stdinStream: const Stream<List<int>>.empty(),
          stdoutSink: session.stdoutSink,
          stderrSink: session.stderrSink,
        ),
        tools: session.fixtureToolsFor(host),
        sdkRepository: session.fixtureSdkRepositoryFor(host),
        log: session.fixtureLog,
        downloader: session.fixtureDownloader,
        currentDirectory: () => '/virtual-compose',
        detectProject: (path, {bundleId, appName, gradleTarget = 'iosArm64'}) =>
            project,
        packProject: ({required project, required options}) async =>
            PackResult(outputPath: 'Demo.app', bundleId: project.bundleId),
      );
      await operation.pack(options: const ComposeBuildOptions());
      expect(app.existsSync(), isFalse);
      expect(framework.existsSync(), isFalse);
      expect(
        files.requests,
        containsAll([
          '/virtual-compose/build/xcross-ios/Demo.app',
          '/virtual-compose/build/xcross-ios/Shared.framework',
        ]),
      );
    },
  );

  group('ComposePackOperation', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('xcross_compose_pack_');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    Future<void> selectedModuleCase(
      ComposeTarget<PlatformHostInterface> target,
      String module,
    ) async {
      File(
        p.join(root.path, 'settings.gradle.kts'),
      ).writeAsStringSync('include(":device", ":simulator")');
      for (final entry in {
        'device': 'iosArm64',
        'simulator': 'iosSimulatorArm64',
      }.entries) {
        File(p.join(root.path, entry.key, 'build.gradle.kts'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
kotlin {
  ${entry.value}()
  binaries.framework { baseName = "${entry.key}" }
}
''');
      }
      final operation = ComposePackOperation.withSeams(
        target,
        log: session.fixtureLog,
        runner: session.fixtureProcessRunner(target.host),
        sdkRepository: session.fixtureSdkRepositoryFor(target.host),
        tools: session.fixtureToolsFor(target.host),
        downloader: session.fixtureDownloader,
        currentDirectory: () => root.path,
        packProject: ({required project, required options}) async {
          expect(project.moduleName, module);
          return PackResult(
            outputPath: '${project.baseName}.framework',
            bundleId: project.bundleId,
            kind: PackOutputKind.framework,
          );
        },
      );
      await operation.pack(options: const ComposeBuildOptions());
    }

    Future<void> missingTargetCase(
      ComposeTarget<PlatformHostInterface> target,
      ComposeTarget<PlatformHostInterface> other,
    ) async {
      const options = ComposeBuildOptions();
      File(
        p.join(root.path, 'settings.gradle.kts'),
      ).writeAsStringSync('include(":shared")');
      File(p.join(root.path, 'shared', 'build.gradle.kts'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
kotlin {
  ${other.gradleTarget}()
  binaries.framework { baseName = "Shared" }
}
''');
      final stale =
          File(
              p.join(
                root.path,
                'build',
                target.outputDirectory,
                'Shared.framework',
                'stale',
              ),
            )
            ..createSync(recursive: true)
            ..writeAsStringSync('preserve');
      final operation = ComposePackOperation.withSeams(
        target,
        log: session.fixtureLog,
        runner: session.fixtureProcessRunner(target.host),
        sdkRepository: session.fixtureSdkRepositoryFor(target.host),
        tools: session.fixtureToolsFor(target.host),
        downloader: session.fixtureDownloader,
        currentDirectory: () => root.path,
        packProject: ({required project, required options}) async =>
            fail('missing selected target must not reach packing'),
      );
      await expectLater(
        operation.pack(options: options),
        throwsA(
          isA<XcrossError>().having(
            (error) => error.message,
            'message',
            contains('No KMP module with ${target.gradleTarget}()'),
          ),
        ),
      );
      expect(stale.readAsStringSync(), 'preserve');
    }

    test(
      'selects device module before pack',
      () => selectedModuleCase(session.fixtureIPhoneTarget, 'device'),
    );
    test(
      'selects simulator module before pack',
      () => selectedModuleCase(session.fixtureSimulatorTarget, 'simulator'),
    );
    test(
      'missing selected device target preserves outputs before pack',
      () => missingTargetCase(
        session.fixtureIPhoneTarget,
        session.fixtureSimulatorTarget,
      ),
    );
    test(
      'missing selected simulator target preserves outputs before pack',
      () => missingTargetCase(
        session.fixtureSimulatorTarget,
        session.fixtureIPhoneTarget,
      ),
    );

    test(
      'simulator pack leaves device outputs and rejects IPA before detection',
      () async {
        final project = _project(root.path, KmpEntryKind.runnableApp);
        final device =
            File(p.join(root.path, 'build', 'xcross-ios', 'Demo.app', 'Runner'))
              ..createSync(recursive: true)
              ..writeAsStringSync('device');
        final stale =
            File(
                p.join(
                  root.path,
                  'build',
                  'xcross-ios-simulator',
                  'Demo.app',
                  'Runner',
                ),
              )
              ..createSync(recursive: true)
              ..writeAsStringSync('simulator');
        var detections = 0;
        final operation = ComposePackOperation.withSeams(
          session.fixtureSimulatorTarget,
          log: session.fixtureLog,
          runner: ProcessRunner(
            log: session.fixtureLog,
            session.fixtureSimulatorTarget.host,
            stdinStream: const Stream<List<int>>.empty(),
            stdoutSink: session.stdoutSink,
            stderrSink: session.stderrSink,
          ),
          tools: session.fixtureToolsFor(session.fixtureSimulatorTarget.host),
          sdkRepository: session.fixtureSdkRepositoryFor(
            session.fixtureSimulatorTarget.host,
          ),
          downloader: session.fixtureDownloader,
          currentDirectory: () => root.path,
          detectProject:
              (path, {bundleId, appName, gradleTarget = 'iosArm64'}) {
                detections++;
                expect(gradleTarget, 'iosSimulatorArm64');
                return project;
              },
          packProject: ({required project, required options}) async {
            expect(stale.existsSync(), isFalse);
            expect(device.readAsStringSync(), 'device');
            return PackResult(
              outputPath: 'simulator.app',
              bundleId: project.bundleId,
            );
          },
        );
        await expectLater(
          operation.pack(options: const ComposeBuildOptions(ipa: true)),
          throwsA(isA<XcrossError>()),
        );
        expect(detections, 0);
        await operation.pack(options: const ComposeBuildOptions());
        expect(detections, 1);
        expect(device.readAsStringSync(), 'device');
      },
    );

    test('detects, deletes stale outputs, then delegates packing', () async {
      final events = <String>[];
      final project = _project(root.path, KmpEntryKind.runnableApp);
      final staleApp = Directory(
        p.join(root.path, 'build', 'xcross-ios', '${project.appName}.app'),
      )..createSync(recursive: true);
      File(p.join(staleApp.path, 'stale')).writeAsStringSync('stale');
      final staleFramework = Directory(
        p.join(
          root.path,
          'build',
          'xcross-ios',
          '${project.baseName}.framework',
        ),
      )..createSync(recursive: true);
      File(p.join(staleFramework.path, 'stale')).writeAsStringSync('stale');

      final operation = ComposePackOperation.withSeams(
        session.fixtureIPhoneTarget,
        log: session.fixtureLog,
        runner: ProcessRunner(
          log: session.fixtureLog,
          session.fixtureIPhoneTarget.host,
          stdinStream: const Stream<List<int>>.empty(),
          stdoutSink: session.stdoutSink,
          stderrSink: session.stderrSink,
        ),
        tools: session.fixtureTools,
        sdkRepository: session.fixtureSdkRepositoryFor(
          session.fixtureIPhoneTarget.host,
        ),
        downloader: session.fixtureDownloader,
        currentDirectory: () => root.path,
        detectProject: (path, {bundleId, appName, gradleTarget = 'iosArm64'}) {
          expect(gradleTarget, 'iosArm64');
          events.add('detect:$path:$bundleId:$appName');
          return project;
        },
        packProject: ({required project, required options}) async {
          events.add('pack');
          expect(staleApp.existsSync(), isFalse);
          expect(staleFramework.existsSync(), isFalse);
          return PackResult(outputPath: 'App.app', bundleId: project.bundleId);
        },
      );

      final result = await operation.pack(
        options: const ComposeBuildOptions(
          bundleId: 'dev.example.override',
          appName: 'OverrideApp',
        ),
      );

      expect(events, [
        'detect:${root.path}:dev.example.override:OverrideApp',
        'pack',
      ]);
      expect(result.kind, PackOutputKind.app);
    });

    test('rejects framework-only run before toolchain work', () async {
      final events = <String>[];
      final operation = ComposePackOperation.withSeams(
        session.fixtureIPhoneTarget,
        log: session.fixtureLog,
        runner: ProcessRunner(
          log: session.fixtureLog,
          session.fixtureIPhoneTarget.host,
          stdinStream: const Stream<List<int>>.empty(),
          stdoutSink: session.stdoutSink,
          stderrSink: session.stderrSink,
        ),
        tools: session.fixtureTools,
        sdkRepository: session.fixtureSdkRepositoryFor(
          session.fixtureIPhoneTarget.host,
        ),
        downloader: session.fixtureDownloader,
        currentDirectory: () => root.path,
        detectProject: (path, {bundleId, appName, gradleTarget = 'iosArm64'}) {
          events.add('detect');
          return _project(root.path, KmpEntryKind.frameworkOnly);
        },
        packProject: ({required project, required options}) async {
          events.add('pack');
          return PackResult(
            outputPath: 'Shared.framework',
            bundleId: project.bundleId,
            kind: PackOutputKind.framework,
          );
        },
      );

      await expectLater(
        operation.pack(
          options: const ComposeBuildOptions(),
          requireRunnableApp: true,
        ),
        throwsA(
          isA<XcrossError>().having(
            (error) => error.message,
            'message',
            contains('framework only'),
          ),
        ),
      );
      expect(events, ['detect']);
    });

    test('rejects framework-only ipa before toolchain work', () async {
      final events = <String>[];
      final operation = ComposePackOperation.withSeams(
        session.fixtureIPhoneTarget,
        log: session.fixtureLog,
        runner: ProcessRunner(
          log: session.fixtureLog,
          session.fixtureIPhoneTarget.host,
          stdinStream: const Stream<List<int>>.empty(),
          stdoutSink: session.stdoutSink,
          stderrSink: session.stderrSink,
        ),
        tools: session.fixtureTools,
        sdkRepository: session.fixtureSdkRepositoryFor(
          session.fixtureIPhoneTarget.host,
        ),
        downloader: session.fixtureDownloader,
        currentDirectory: () => root.path,
        detectProject: (path, {bundleId, appName, gradleTarget = 'iosArm64'}) {
          events.add('detect');
          return _project(root.path, KmpEntryKind.frameworkOnly);
        },
        packProject: ({required project, required options}) async {
          events.add('pack');
          return PackResult(
            outputPath: 'Shared.framework',
            bundleId: project.bundleId,
            kind: PackOutputKind.framework,
          );
        },
      );

      await expectLater(
        operation.pack(options: const ComposeBuildOptions(ipa: true)),
        throwsA(isA<XcrossError>()),
      );
      expect(events, ['detect']);
    });
  });

  group('ComposePacker', () {
    test(
      'runs toolchain, Gradle, framework, ObjC runner, and assemble in order',
      () async {
        final root = Directory.systemTemp.createTempSync(
          'xcross_compose_packer_',
        );
        addTearDown(() {
          if (root.existsSync()) root.deleteSync(recursive: true);
        });
        final events = <String>[];
        final project = _project(root.path, KmpEntryKind.runnableApp);
        final packer = _packer(
          session,
          project: project,
          events: events,
          objcRunner:
              ({
                required project,
                required frameworkPath,
                required toolchain,
              }) async {
                events.add('objc-runner');
                return 'Runner';
              },
        );

        final result = await packer.pack();

        expect(events, [
          'toolchain',
          'gradle-klib',
          'framework',
          'objc-runner',
          'assemble',
        ]);
        expect(
          result.outputPath,
          p.join(root.path, 'build', 'xcross-ios', 'Demo.app'),
        );
        expect(result.bundleId, 'dev.example.demo');
        expect(result.kind, PackOutputKind.app);
      },
    );

    test('uses the Swift runner for Swift app projects', () async {
      final root = Directory.systemTemp.createTempSync('xcross_compose_swift_');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final events = <String>[];
      final project = _project(root.path, KmpEntryKind.swiftApp);
      final packer = _packer(
        session,
        project: project,
        events: events,
        swiftRunner:
            ({
              required project,
              required frameworkPath,
              required toolchain,
            }) async {
              events.add('swift-runner');
              return 'Runner';
            },
      );

      await packer.pack();

      expect(events, [
        'toolchain',
        'gradle-klib',
        'framework',
        'swift-runner',
        'assemble',
      ]);
    });

    test(
      'returns framework output early for framework-only projects',
      () async {
        final root = Directory.systemTemp.createTempSync(
          'xcross_compose_framework_',
        );
        addTearDown(() {
          if (root.existsSync()) root.deleteSync(recursive: true);
        });
        final events = <String>[];
        final project = _project(root.path, KmpEntryKind.frameworkOnly);
        final packer = _packer(session, project: project, events: events);

        final result = await packer.pack();

        expect(events, ['toolchain', 'gradle-klib', 'framework']);
        expect(
          result.outputPath,
          p.join(root.path, 'build', 'xcross-ios', 'Shared.framework'),
        );
        expect(result.kind, PackOutputKind.framework);
      },
    );

    test('ensures the toolchain exactly once', () async {
      final root = Directory.systemTemp.createTempSync('xcross_compose_once_');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      var ensures = 0;
      final packer = _packer(
        session,
        project: _project(root.path, KmpEntryKind.frameworkOnly),
        events: <String>[],
        ensureToolchain:
            ({
              required environment,
              required projectRoot,
              required allowInstall,
              required force,
            }) async {
              ensures++;
              return _toolchain(session);
            },
      );

      await packer.pack();

      expect(ensures, 1);
    });
  });
}

ComposePacker _packer(
  ComposeTestSession session, {
  required KmpProject project,
  required List<String> events,
  ComposeEnsureToolchain? ensureToolchain,
  ComposeBuildRunner? objcRunner,
  ComposeBuildRunner? swiftRunner,
}) => ComposePacker.withSeams(
  log: session.fixtureLog,
  project: project,
  options: const ComposeBuildOptions(),
  target: session.fixtureIPhoneTarget,
  runner: session.fixtureRunner,
  tools: session.fixtureTools,
  sdkRepository: session.fixtureSdkRepositoryFor(
    session.fixtureIPhoneTarget.host,
  ),
  downloader: session.fixtureDownloader,
  ensureToolchain:
      ensureToolchain ??
      ({
        required environment,
        required projectRoot,
        required allowInstall,
        required force,
      }) async {
        events.add('toolchain');
        return _toolchain(session);
      },
  buildKlib: ({required project, required toolchain}) async {
    events.add('gradle-klib');
    return const GradleKlibResult(
      moduleKlibPath: 'module.klib',
      dependencies: [],
    );
  },
  buildFramework:
      ({
        required project,
        required options,
        required toolchain,
        required klib,
      }) async {
        events.add('framework');
        return p.join(
          project.root,
          'build',
          'xcross-ios',
          '${project.baseName}.framework',
        );
      },
  buildObjcRunner:
      objcRunner ??
      ({required project, required frameworkPath, required toolchain}) async {
        events.add('unexpected-objc-runner');
        return 'Runner';
      },
  buildSwiftRunner:
      swiftRunner ??
      ({required project, required frameworkPath, required toolchain}) async {
        events.add('unexpected-swift-runner');
        return 'Runner';
      },
  assembleApp:
      ({required project, required runnerPath, required frameworkPath}) async {
        events.add('assemble');
        return p.join(
          project.root,
          'build',
          'xcross-ios',
          '${project.appName}.app',
        );
      },
);

KmpProject _project(String root, KmpEntryKind entryKind) => KmpProject(
  root: root,
  modulePath: p.join(root, 'shared'),
  moduleName: 'shared',
  baseName: 'Shared',
  entryKind: entryKind,
  bundleId: 'dev.example.demo',
  appName: 'Demo',
  swiftSources: entryKind == KmpEntryKind.swiftApp
      ? [p.join(root, 'iosApp', 'App.swift')]
      : const [],
);

ComposeToolchain _toolchain(ComposeTestSession session) => ComposeToolchain(
  log: session.fixtureLog,
  target: session.fixtureIPhoneTarget,
  runner: session.fixtureRunner,
  kotlinHome: '/kotlin',
  konanCache: '/konan-cache',
  konancExecutable: '/kotlin/bin/konanc',
  javaHome: '/jdk',
  javaExecutable: '/jdk/bin/java',
  gradleExecutable: '/gradle/bin/gradle',
  swiftc: '/swift/bin/swiftc',
  clang: '/llvm/bin/clang',
  ld64Lld: '/llvm/bin/ld64.lld',
  darwinSdkPath: '/sdk',
  darwinSdkBundle: '/sdk-bundle',
);
