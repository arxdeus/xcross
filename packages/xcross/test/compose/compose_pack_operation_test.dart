import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/compose/build/compose_pack_operation.dart';
import 'package:xcross/src/compose/build/compose_packer.dart';
import 'package:xcross/src/compose/build/gradle_klib_builder.dart';
import 'package:xcross/src/compose/models/compose_build_options.dart';
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/compose/toolchain/compose_host.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/models/pack_result.dart';

void main() {
  group('ComposePackOperation', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('xcross_compose_pack_');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

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
        currentDirectory: () => root.path,
        detectProject: (path, {bundleId, appName}) {
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
        currentDirectory: () => root.path,
        detectProject: (path, {bundleId, appName}) {
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
        currentDirectory: () => root.path,
        detectProject: (path, {bundleId, appName}) {
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
        final packer = _packer(project: project, events: events);

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
        project: _project(root.path, KmpEntryKind.frameworkOnly),
        events: <String>[],
        ensureToolchain:
            ({
              required host,
              required environment,
              required projectRoot,
              required allowInstall,
              required force,
            }) async {
              ensures++;
              return _toolchain;
            },
      );

      await packer.pack();

      expect(ensures, 1);
    });
  });
}

ComposePacker _packer({
  required KmpProject project,
  required List<String> events,
  ComposeEnsureToolchain? ensureToolchain,
  ComposeBuildObjcRunner? objcRunner,
  ComposeBuildSwiftRunner? swiftRunner,
}) => ComposePacker.withSeams(
  project: project,
  options: const ComposeBuildOptions(),
  currentHost: () => ComposeHost.linuxX64,
  environment: () => const <String, String>{},
  ensureToolchain:
      ensureToolchain ??
      ({
        required host,
        required environment,
        required projectRoot,
        required allowInstall,
        required force,
      }) async {
        events.add('toolchain');
        return _toolchain;
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

const _toolchain = ComposeToolchain(
  host: ComposeHost.linuxX64,
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
