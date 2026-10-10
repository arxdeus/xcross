@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_build_platform.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/flutter_aot_snapshotter.dart';
import 'package:xcross/src/shared/flutter/build/impeller_shader_compiler.dart';
import 'package:xcross/src/shared/flutter/build/internal/runner_binary.dart';
import 'package:xcross/src/shared/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/shared/flutter/build/ios_native_assets.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/flutter_artifact_compiler.dart';
import 'package:xcross/src/shared/flutter/flutter_assets_compiler.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/flutter_build_steps.dart';
import 'package:xcross/src/shared/flutter/flutter_bundle_assembler.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/ios_gen_snapshot_mode.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_options.dart';

import '../flutter_test_log.dart';
import '../flutter_test_runtime.dart';

const _engine = '5f77625673248ee5846fbcaf5d3e1a3878386fd7';

void main() {
  late Directory tmp;
  late String tools;
  late String calls;
  late RecordingFlutterLogOutput output;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xcross_aot_outputs_');
    tools = p.join(tmp.path, 'tools');
    calls = p.join(tmp.path, 'calls.log');
    output = RecordingFlutterLogOutput();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A stand-in tool in [directory] that records its invocation in [calls].
  String tool(String name, String body, {String? directory}) {
    final file = File(p.join(directory ?? tools, name))
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\necho "\$0 \$*" >> "$calls"\n$body\n');
    Process.runSync('/bin/chmod', ['+x', file.path]);
    return file.path;
  }

  /// `dsymutil -o <dsym> <binary>` that writes a dSYM bundle.
  String workingDsymutil({String? directory}) => tool('dsymutil', r'''
/bin/mkdir -p "$2/Contents/Resources/DWARF"
/bin/cp "$3" "$2/Contents/Resources/DWARF/$(/usr/bin/basename "$3")"
''', directory: directory);

  /// An assertion-enabled `dsymutil` that aborts after a partial write.
  String crashingDsymutil({String? directory}) => tool('dsymutil', r'''
/bin/mkdir -p "$2/Contents"
echo 'Invalid form for specified DWARF version' >&2
echo 'UNREACHABLE executed at DIE.cpp:84!' >&2
kill -SEGV $$
''', directory: directory);

  String strip() => tool('llvm-strip', '');

  List<String> recorded() {
    final file = File(calls);
    return file.existsSync() ? file.readAsLinesSync() : const [];
  }

  FlutterBuildRuntime<LinuxHost> runtime({
    List<String>? path,
    IosAotCompilerLocator? aotCompilers,
  }) => testIPhoneRuntime(
    environment: {
      'PATH': (path ?? [tools]).join(':'),
      'XDG_CACHE_HOME': p.join(tmp.path, 'cache'),
    },
    llvmToolDirectories: const [],
    log: Log(output: output),
    aotCompilers: aotCompilers,
  );

  String binary(String name) {
    final file = File(p.join(tmp.path, 'out', name))
      ..createSync(recursive: true)
      ..writeAsStringSync('mach-o');
    return file.path;
  }

  group('AppleDebugSymbols', () {
    test('warns once and leaves no dSYM without dsymutil', () async {
      final symbols = runtime().debugSymbols;
      final stale = Directory(p.join(tmp.path, 'out', 'App.framework.dSYM'))
        ..createSync(recursive: true);
      expect(await symbols.extract(binary('App'), stale.path), isFalse);
      expect(await symbols.extract(binary('Other'), '${stale.path}2'), isFalse);
      expect(stale.existsSync(), isFalse);
      expect(output.errors, hasLength(1));
      expect(
        output.errors.single,
        allOf(contains('dsymutil not found'), contains('App.framework.dSYM')),
      );
    });

    test(
      'tries Swift toolchain dsymutil last and keeps the working one',
      () async {
        final swift = p.join(tmp.path, 'swift-toolchain');
        crashingDsymutil(directory: swift);
        File(p.join(swift, 'swift')).writeAsStringSync('');
        final working = workingDsymutil(directory: p.join(tmp.path, 'llvm'));
        final symbols = runtime(path: [swift, p.dirname(working)]).debugSymbols;
        final dsym = p.join(tmp.path, 'out', 'App.framework.dSYM');
        expect(await symbols.extract(binary('App'), dsym), isTrue);
        expect(
          File(
            p.join(dsym, 'Contents', 'Resources', 'DWARF', 'App'),
          ).existsSync(),
          isTrue,
        );
        expect(recorded().map((line) => line.split(' ').first), [working]);
        expect(output.errors, isEmpty);
      },
    );

    test(
      'falls back past a crashing dsymutil and removes its partial dSYM',
      () async {
        final crashing = crashingDsymutil(directory: p.join(tmp.path, 'a'));
        final working = workingDsymutil(directory: p.join(tmp.path, 'b'));
        final symbols = runtime(
          path: [p.dirname(crashing), p.dirname(working)],
        ).debugSymbols;
        final dsym = p.join(tmp.path, 'out', 'App.framework.dSYM');
        expect(await symbols.extract(binary('App'), dsym), isTrue);
        expect(
          Directory(
            p.join(dsym, 'Contents', 'Resources', 'DWARF'),
          ).existsSync(),
          isTrue,
        );
        expect(recorded().map((line) => line.split(' ').first), [
          crashing,
          working,
        ]);
        File(calls).deleteSync();
        expect(await symbols.extract(binary('Other'), '$dsym.2'), isTrue);
        expect(recorded().map((line) => line.split(' ').first), [
          working,
        ], reason: 'the dsymutil that worked is tried first afterwards');
        expect(output.errors, isEmpty);
      },
    );

    test('a failing dsymutil does not fail the build', () async {
      final crashing = crashingDsymutil();
      final symbols = runtime().debugSymbols;
      final dsym = p.join(tmp.path, 'out', 'App.framework.dSYM');
      expect(await symbols.extract(binary('App'), dsym), isFalse);
      expect(await symbols.extract(binary('App'), dsym), isFalse);
      expect(Directory(dsym).existsSync(), isFalse);
      expect(output.errors, hasLength(1));
      expect(
        output.errors.single,
        allOf(
          contains('No App.framework.dSYM'),
          contains(crashing),
          contains('crashed'),
          contains('UNREACHABLE'),
          contains('Install an LLVM release'),
        ),
      );
    });
  });

  group('FlutterAotSnapshotter', () {
    String genSnapshot() => tool('gen_snapshot', r'''
for argument in "$@"; do
  case "$argument" in
    --macho=*) printf 'aot' > "${argument#--macho=}" ;;
  esac
done
''');

    test(
      'passes the engine floor and writes the dSYM before stripping',
      () async {
        workingDsymutil();
        final stripTool = strip();
        final build = runtime();
        final framework = p.join(tmp.path, 'out', 'App.framework');
        await FlutterAotSnapshotter(
          runtime: build,
          compiler: genSnapshot(),
          minimumOsVersion: '16.4',
        ).compile(
          appDill: p.join(tmp.path, 'app.dill'),
          appFramework: framework,
          objectFile: p.join(tmp.path, 'out', 'app.o'),
        );
        final lines = recorded();
        expect(lines, hasLength(3));
        expect(lines[0], contains('--macho-min-os-version=16.4'));
        expect(lines[1], contains('-o $framework.dSYM $framework/App'));
        expect(lines[2], '$stripTool -x $framework/App -o $framework/App');
        expect(
          File(
            p.join('$framework.dSYM', 'Contents', 'Resources', 'DWARF', 'App'),
          ).readAsStringSync(),
          'aot',
        );
      },
    );

    test('defaults to Flutter 15.0 floor', () {
      expect(
        FlutterAotSnapshotter.arguments(
          appDill: 'app.dill',
          binary: 'App',
          objectFile: 'app.o',
          minimumOsVersion: '17.0',
        ),
        contains('--macho-min-os-version=17.0'),
      );
      expect(FlutterAotSnapshotter.fallbackMinimumOsVersion, '15.0');
    });
  });

  group('AOT compiler selection', () {
    late String project;
    late String flutterRoot;

    setUp(() {
      project = p.join(tmp.path, 'project');
      File(p.join(project, 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('name: fixture\n');
      flutterRoot = p.join(tmp.path, 'flutter');
      File(p.join(flutterRoot, 'bin', 'internal', 'engine.version'))
        ..createSync(recursive: true)
        ..writeAsStringSync('$_engine\n');
    });

    String sdkEngine(String artifact) =>
        p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'engine', artifact);

    void writeEngine(
      String engineDirectory, {
      required String revision,
      String? minimumOsVersion,
    }) {
      final framework = Directory(
        p.join(
          engineDirectory,
          'Flutter.xcframework',
          'ios-arm64',
          'Flutter.framework',
        ),
      )..createSync(recursive: true);
      File(p.join(framework.path, 'Flutter')).writeAsStringSync('engine');
      File(p.join(framework.path, 'Info.plist')).writeAsStringSync(
        PropertyListSerialization.stringWithPropertyList({
          'CFBundleExecutable': 'Flutter',
          'FlutterEngine': revision,
          'MinimumOSVersion': ?minimumOsVersion,
        }),
      );
    }

    FlutterArtifactCompiler<LinuxHost> compiler(
      FlutterBuildMode mode, {
      IosAotCompilerLocator? aotCompilers,
    }) {
      final build = runtime(aotCompilers: aotCompilers);
      return FlutterArtifactCompiler(
        FlutterBuildContext(
          request: FlutterBuildRequest(
            runtime: build,
            projectRoot: project,
            bundleId: 'com.example.fixture',
            options: FlutterBuildOptions(pub: false, buildMode: mode),
          ),
          flutterRoot: flutterRoot,
        ),
      );
    }

    test('debug builds need no AOT compiler', () {
      expect(compiler(FlutterBuildMode.debug).aotSnapshotter(), isNull);
    });

    for (final mode in [FlutterBuildMode.profile, FlutterBuildMode.release]) {
      test('${mode.name} fails without an AOT compiler', () {
        expect(
          () => compiler(mode).aotSnapshotter(),
          throwsA(
            isA<FlutterBuildError>().having(
              (error) => error.message,
              'message',
              contains('${mode.name} builds need the iOS AOT compiler'),
            ),
          ),
        );
      });
    }

    final requests = <({String flutterRoot, String engineDirectory})>[];
    Future<String> locate({
      required String flutterRoot,
      required String engineDirectory,
      required IosGenSnapshotMode mode,
    }) async {
      requests.add((
        flutterRoot: flutterRoot,
        engineDirectory: engineDirectory,
      ));
      return p.join(engineDirectory, 'gen_snapshot_arm64');
    }

    setUp(requests.clear);

    test('uses the SDK engine and its MinimumOSVersion when current', () async {
      writeEngine(
        sdkEngine('ios-release'),
        revision: _engine,
        minimumOsVersion: '16.0',
      );
      final build = compiler(FlutterBuildMode.release, aotCompilers: locate);
      final snapshotter = await build.aotSnapshotter()!(
        build.runtime.engineCache(flutterRoot, mode: FlutterBuildMode.release),
      );
      expect(requests.single.flutterRoot, flutterRoot);
      expect(requests.single.engineDirectory, sdkEngine('ios-release'));
      expect(
        snapshotter.compiler,
        p.join(sdkEngine('ios-release'), 'gen_snapshot_arm64'),
      );
      expect(snapshotter.minimumOsVersion, '16.0');
    });

    test(
      'uses the engine the build downloads when the SDK one is stale',
      () async {
        writeEngine(
          sdkEngine('ios-profile'),
          revision: 'older-engine',
          minimumOsVersion: '13.0',
        );
        final cached = p.join(
          tmp.path,
          'cache',
          'xcross',
          'flutter-engine',
          _engine,
          'artifacts',
          'engine',
          'ios-profile',
        );
        writeEngine(cached, revision: _engine);
        final build = compiler(FlutterBuildMode.profile, aotCompilers: locate);
        final snapshotter = await build.aotSnapshotter()!(
          build.runtime.engineCache(
            flutterRoot,
            mode: FlutterBuildMode.profile,
          ),
        );
        expect(requests.single.engineDirectory, cached);
        expect(
          build.runtime
              .engineCache(
                flutterRoot,
                mode: FlutterBuildMode.of(IosGenSnapshotMode.profile),
              )
              .engineDirectory,
          cached,
          reason: 'precache and doctor look where the build compiles from',
        );
        expect(snapshotter.compiler, p.join(cached, 'gen_snapshot_arm64'));
        expect(
          snapshotter.minimumOsVersion,
          FlutterAotSnapshotter.fallbackMinimumOsVersion,
        );
      },
    );
  });

  group('native asset frameworks', () {
    late String flutterRoot;

    setUp(() {
      flutterRoot = p.join(tmp.path, 'flutter');
    });

    IosNativeAssetsBuilder<LinuxHost> builder(
      FlutterBuildRuntime<LinuxHost> build,
      FlutterBuildMode mode,
    ) => IosNativeAssetsBuilder(
      nativeAssetFrameworks: build.nativeAssetFrameworks,
      hooks: build.nativeAssetHooks,
      runner: build.runner,
      tools: build.nativeTools,
      engineCache: build.engineCache(flutterRoot, mode: mode),
      renderer: build.toolShimRenderer,
      projectRoot: p.join(tmp.path, 'project'),
      flutterRoot: flutterRoot,
      deploymentTarget: const IosDeploymentTarget(
        '15.0',
        platform: IPhoneBuildPlatform(),
      ),
      debugSymbols: build.debugSymbols,
    );

    String framework(String name) {
      File(p.join(tmp.path, 'staged', '$name.framework', name))
        ..createSync(recursive: true)
        ..writeAsStringSync(name);
      return p.join(tmp.path, 'staged', '$name.framework');
    }

    for (final mode in [FlutterBuildMode.profile, FlutterBuildMode.release]) {
      test('${mode.name} writes dSYMs, then strips', () async {
        workingDsymutil();
        final stripTool = strip();
        final first = framework('First');
        final second = framework('Second');
        await builder(runtime(), mode).stripFrameworks([first, second]);
        final lines = recorded();
        expect(lines, hasLength(4));
        expect(lines[0], endsWith('-o $first.dSYM $first/First'));
        expect(lines[1], endsWith('-o $second.dSYM $second/Second'));
        expect(lines[2], '$stripTool -x -S $first/First -o $first/First');
        expect(lines[3], '$stripTool -x -S $second/Second -o $second/Second');
        expect(Directory('$first.dSYM').existsSync(), isTrue);
        expect(Directory('$second.dSYM').existsSync(), isTrue);
      });
    }

    test('debug keeps native asset symbols', () async {
      workingDsymutil();
      strip();
      final first = framework('First');
      await builder(runtime(), FlutterBuildMode.debug).stripFrameworks([first]);
      expect(recorded(), isEmpty);
      expect(Directory('$first.dSYM').existsSync(), isFalse);
    });

    test('warns when llvm-strip is missing but still writes dSYMs', () async {
      workingDsymutil();
      final first = framework('First');
      await builder(
        runtime(),
        FlutterBuildMode.release,
      ).stripFrameworks([first]);
      expect(Directory('$first.dSYM').existsSync(), isTrue);
      expect(
        output.errors.single,
        contains('llvm-strip not found; native asset frameworks keep'),
      );
    });
  });

  group('FlutterBundleAssembler', () {
    late String project;
    late String app;
    late String xcframework;
    late String native;
    late String runner;

    setUp(() {
      project = p.join(tmp.path, 'project');
      File(p.join(project, 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('name: fixture\n');
      app = p.join(tmp.path, 'compiled', 'App.framework');
      File(p.join(app, 'App'))
        ..createSync(recursive: true)
        ..writeAsStringSync('aot');
      xcframework = p.join(tmp.path, 'engine', 'Flutter.xcframework');
      File(p.join(xcframework, 'ios-arm64', 'Flutter.framework', 'Flutter'))
        ..createSync(recursive: true)
        ..writeAsStringSync('engine');
      native = p.join(tmp.path, 'native', 'Native.framework');
      File(p.join(native, 'Native'))
        ..createSync(recursive: true)
        ..writeAsStringSync('native');
      runner = p.join(tmp.path, 'Runner');
      File(runner).writeAsStringSync('runner');
    });

    void dsym(String bundle, String name) =>
        File(p.join(bundle, 'Contents', 'Resources', 'DWARF', name))
          ..createSync(recursive: true)
          ..writeAsStringSync('dwarf $name');

    Future<String> assemble(FlutterBuildMode mode) {
      final build = runtime();
      return FlutterBundleAssembler(
        FlutterBuildContext(
          request: FlutterBuildRequest(
            runtime: build,
            projectRoot: project,
            bundleId: 'com.example.fixture',
            options: FlutterBuildOptions(pub: false, buildMode: mode),
          ),
          flutterRoot: '/unused',
        ),
      ).assemble(
        FlutterLinkedArtifacts(
          compiled: FlutterCompiledArtifacts(
            appFramework: app,
            nativeAssets: IosNativeAssetsBuildResult(
              manifestPath: '/unused',
              frameworks: [native],
            ),
          ),
          runner: RunnerBinary(
            xcframework: xcframework,
            runnerBinary: runner,
            sdkName: build.target.buildPlatform.sdkName,
          ),
          extensions: const [],
        ),
      );
    }

    String outputDir() => p.join(project, 'build', 'xcross-ios');

    test('release places dSYMs beside the app; debug removes them', () async {
      dsym('$app.dSYM', 'App');
      dsym(
        p.join(xcframework, 'ios-arm64', 'dSYMs', 'Flutter.framework.dSYM'),
        'Flutter',
      );
      dsym('$native.dSYM', 'Native');
      final stale = Directory(p.join(outputDir(), 'Gone.framework.dSYM'))
        ..createSync(recursive: true);

      final bundle = await assemble(FlutterBuildMode.release);
      expect(p.dirname(bundle), outputDir());
      for (final name in ['App', 'Flutter', 'Native']) {
        expect(
          File(
            p.join(
              outputDir(),
              '$name.framework.dSYM',
              'Contents',
              'Resources',
              'DWARF',
              name,
            ),
          ).readAsStringSync(),
          'dwarf $name',
        );
      }
      expect(stale.existsSync(), isFalse);

      await assemble(FlutterBuildMode.debug);
      expect(
        Directory(outputDir())
            .listSync()
            .map((entity) => p.basename(entity.path))
            .where((name) => name.endsWith('.dSYM')),
        isEmpty,
      );
      expect(Directory(bundle).existsSync(), isTrue);
    });

    test('a build without dSYMs ships none', () async {
      dsym('$app.dSYM', 'App');
      await assemble(FlutterBuildMode.profile);
      Directory('$app.dSYM').deleteSync(recursive: true);
      await assemble(FlutterBuildMode.release);
      expect(
        Directory(p.join(outputDir(), 'App.framework.dSYM')).existsSync(),
        isFalse,
      );
    });

    test('release drops the VM service discovery keys profile keeps', () async {
      String plist(String bundle) =>
          File(p.join(bundle, 'Info.plist')).readAsStringSync();
      final profile = plist(await assemble(FlutterBuildMode.profile));
      expect(profile, contains('<key>NSBonjourServices</key>'));
      expect(profile, contains('_dartVmService._tcp'));
      expect(profile, contains('<key>NSLocalNetworkUsageDescription</key>'));
      final release = plist(await assemble(FlutterBuildMode.release));
      expect(release, isNot(contains('NSBonjourServices')));
      expect(release, isNot(contains('_dartVmService')));
      expect(release, isNot(contains('NSLocalNetworkUsageDescription')));
    });
  });

  group('FlutterAssetsCompiler', () {
    for (final precompiled in [true, false]) {
      test('${precompiled ? 'precompiled' : 'debug'} bundles '
          '${precompiled ? 'no' : 'the'} JIT kernel and snapshots', () async {
        final project = p.join(tmp.path, 'project');
        File(p.join(project, 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('name: fixture\n');
        File(p.join(project, '.dart_tool', 'package_config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync('{"configVersion":2,"packages":[]}');
        String input(String name) {
          final file = File(p.join(tmp.path, 'inputs', name))
            ..createSync(recursive: true)
            ..writeAsStringSync(name);
          return file.path;
        }

        final build = runtime();
        final assets = p.join(tmp.path, 'flutter_assets');
        Directory(assets).createSync();
        await FlutterAssetsCompiler(
          fileSystem: build.host.fileSystem,
          paths: build.host.paths.context,
          projectRoot: project,
          flutterRoot: p.join(tmp.path, 'flutter'),
        ).bundle(
          assetsDir: assets,
          appDill: input('app.dill'),
          vmSnapshotData: input('vm_isolate_snapshot.bin'),
          isolateSnapshotData: input('isolate_snapshot.bin'),
          pubspec: build.pubspecs.loadSync(project),
          shaders: ImpellerShaderCompiler(
            runner: build.runner,
            impellerc: '/unused/impellerc',
            shaderLib: '/unused/shader_lib',
          ),
          precompiled: precompiled,
        );
        for (final name in [
          'kernel_blob.bin',
          'vm_snapshot_data',
          'isolate_snapshot_data',
        ]) {
          expect(
            File(p.join(assets, name)).existsSync(),
            !precompiled,
            reason: name,
          );
        }
        expect(File(p.join(assets, 'AssetManifest.bin')).existsSync(), isTrue);
      });
    }
  });
}
