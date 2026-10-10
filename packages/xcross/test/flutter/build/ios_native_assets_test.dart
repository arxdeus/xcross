import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:darwin_sdk_kit/host/linux/linux_darwin_toolchain_locations.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_target.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:darwin_sdk_kit/target/simulator/simulator_build_platform.dart';
import 'package:darwin_sdk_kit/target/simulator/simulator_target.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/linux/flutter/native_host_tools.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer_posix.dart';
import 'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/shared/flutter/build/internal/native_asset_frameworks.dart';
import 'package:xcross/src/shared/flutter/build/internal/native_assets_hook_discovery.dart';
import 'package:xcross/src/shared/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/shared/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/shared/flutter/build/ios_native_assets.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/packages/package_config_resolver.dart';
import 'package:xcross/src/target/simulator/flutter/simulator_flutter_target.dart';

import '../../host_operations_fixtures.dart';
import 'macho_linkedit_aligner_test.dart';
import 'support/native_asset_framework_fixtures.dart';
import 'support/native_flutter_fixtures.dart';

void main() {
  final fixtureHost = LinuxHost();
  final frameworks = nativeFrameworkService(
    fixtureRunner(fixtureHost, log: fixtureLog()),
  );

  test(
    testOn: '!windows',
    'native hook assembly preserves target, manifest and flavor inputs',
    () {
      final host = LinuxHost(architecture: 'arm64');
      final runner = ProcessRunner(
        host,
        log: nativeTestLog(),
        stdinStream: const Stream<List<int>>.empty(),
        stdoutSink: nativeTestSink(),
        stderrSink: nativeTestSink(),
      );
      final hostTools = LinuxNativeHostTools(host, runner);
      final target = SimulatorTarget(host);
      final cache = IosEngineCache(
        targetPolicy: SimulatorFlutterTarget(target),
        hostTools: hostTools,
        flutterRoot: '/flutter',
        log: nativeTestLog(),
        downloader: nativeTestDownloader(),
      );
      final builder = IosNativeAssetsBuilder(
        nativeAssetFrameworks: nativeFrameworkService(runner),
        hooks: NativeAssetsHookDiscovery(
          fileSystem: host.fileSystem,
          paths: host.paths.context,
          packageConfigs: PackageConfigResolver(
            fileSystem: host.fileSystem,
            paths: host.paths.context,
          ),
        ),
        engineCache: cache,
        renderer: PosixAppleToolShimRenderer(host),
        runner: runner,
        tools: AppleToolShimResolver(
          target,
          runner,
          DarwinSdkRepository(host, log: nativeTestLog()),
          DarwinToolchainResolver(runner, LinuxDarwinToolchainLocations(host)),
          hostTools: hostTools,
          executable: '/xcross',
        ),
        projectRoot: '/project',
        flutterRoot: '/flutter',
        deploymentTarget: const IosDeploymentTarget(
          '15.0',
          platform: SimulatorBuildPlatform(),
        ),
        entrypoint: 'lib/flavored.dart',
        dartDefines: const ['CUSTOM=value'],
        flavor: 'development',
      );
      final arguments = builder.assembleArguments(
        output: '/output',
        iosSdk: '/simulator-sdk',
      );
      expect(
        arguments,
        containsAll([
          '-dTargetPlatform=ios',
          '-dBuildMode=debug',
          '-dIosArchs=arm64',
          '-dSdkRoot=/simulator-sdk',
          '-dTargetFile=lib/flavored.dart',
          '-dIosDeploymentTarget=15.0',
          'debug_ios_bundle_flutter_assets',
        ]),
      );
      final defines = arguments
          .singleWhere((arg) => arg.startsWith('-dDartDefines='))
          .substring('-dDartDefines='.length)
          .split(',')
          .map((value) => utf8.decode(base64.decode(value)));
      expect(
        defines,
        containsAll(['CUSTOM=value', 'FLUTTER_APP_FLAVOR=development']),
      );
      expect(
        builder.assembleArguments(output: '/bundle').last,
        'copy_flutter_bundle',
      );
      expect(
        cache.targetPolicy.buildDirectory('/project', 'xcross-native-assets'),
        p.join(
          '/project',
          'build',
          'xcross-ios-simulator',
          'xcross-native-assets',
        ),
      );
    },
  );

  test('native builder rejects mixed target, host and SDK contexts', () {
    final host = LinuxHost(architecture: 'arm64');
    final otherHost = LinuxHost(architecture: 'arm64');
    final runner = ProcessRunner(
      host,
      log: nativeTestLog(),
      stdinStream: const Stream<List<int>>.empty(),
      stdoutSink: nativeTestSink(),
      stderrSink: nativeTestSink(),
    );
    final otherRunner = ProcessRunner(
      otherHost,
      log: nativeTestLog(),
      stdinStream: const Stream<List<int>>.empty(),
      stdoutSink: nativeTestSink(),
      stderrSink: nativeTestSink(),
    );
    final hostTools = LinuxNativeHostTools(host, runner);
    final target = SimulatorTarget(host);
    final cache = IosEngineCache(
      targetPolicy: SimulatorFlutterTarget(target),
      hostTools: hostTools,
      flutterRoot: '/flutter',
      log: nativeTestLog(),
      downloader: nativeTestDownloader(),
    );
    AppleToolShimResolver<LinuxHost> resolver(IosTarget<LinuxHost> selected) =>
        AppleToolShimResolver(
          selected,
          runner,
          DarwinSdkRepository(host, log: nativeTestLog()),
          DarwinToolchainResolver(runner, LinuxDarwinToolchainLocations(host)),
          hostTools: hostTools,
          executable: '/xcross',
        );
    IosNativeAssetsBuilder<LinuxHost> create({
      IosTarget<LinuxHost>? selected,
      LinuxHost? renderHost,
      ProcessRunner<LinuxHost>? processRunner,
      String flutterRoot = '/flutter',
      NativeAssetFrameworks<LinuxHost>? frameworkService,
    }) => IosNativeAssetsBuilder(
      nativeAssetFrameworks: frameworkService ?? nativeFrameworkService(runner),
      hooks: NativeAssetsHookDiscovery(
        fileSystem: host.fileSystem,
        paths: host.paths.context,
        packageConfigs: PackageConfigResolver(
          fileSystem: host.fileSystem,
          paths: host.paths.context,
        ),
      ),
      engineCache: cache,
      renderer: PosixAppleToolShimRenderer(renderHost ?? host),
      runner: processRunner ?? runner,
      tools: resolver(selected ?? target),
      projectRoot: '/project',
      flutterRoot: flutterRoot,
      deploymentTarget: const IosDeploymentTarget(
        '15.0',
        platform: SimulatorBuildPlatform(),
      ),
    );
    expect(() => create(selected: IPhoneTarget(host)), throwsArgumentError);
    expect(() => create(renderHost: otherHost), throwsArgumentError);
    expect(() => create(processRunner: otherRunner), throwsArgumentError);
    expect(() => create(flutterRoot: '/different-sdk'), throwsArgumentError);
    expect(
      () => create(frameworkService: nativeFrameworkService(otherRunner)),
      throwsArgumentError,
    );
    final sameHostRunner = fixtureRunner(host, log: fixtureLog());
    expect(
      () => create(frameworkService: nativeFrameworkService(sameHostRunner)),
      throwsArgumentError,
    );
    expect(() => LinuxNativeHostTools(host, otherRunner), throwsArgumentError);
    expect(create, returnsNormally);
  });

  test(
    testOn: '!windows',
    'detects build hooks through package_config root URIs',
    () async {
      final tmp = await Directory.systemTemp.createTemp('hook_detection_test-');
      try {
        final package = Directory(p.join(tmp.path, 'dependency'))..createSync();
        Directory(p.join(package.path, 'hook')).createSync();
        File(p.join(package.path, 'hook', 'build.dart')).writeAsStringSync('');
        final dartTool = Directory(p.join(tmp.path, 'app', '.dart_tool'))
          ..createSync(recursive: true);
        File(p.join(dartTool.path, 'package_config.json')).writeAsStringSync('''
{"configVersion":2,"packages":[{"name":"dependency","rootUri":"../../dependency","packageUri":"lib/"}]}
''');

        expect(
          await nativeHookDiscovery().hasBuildHooks(p.join(tmp.path, 'app')),
          isTrue,
        );
        File(p.join(package.path, 'hook', 'build.dart')).deleteSync();
        expect(
          await nativeHookDiscovery().hasBuildHooks(p.join(tmp.path, 'app')),
          isFalse,
        );
      } finally {
        await tmp.delete(recursive: true);
      }
    },
  );

  test(
    testOn: '!windows',
    'reports malformed package config clearly',
    () async {
      final tmp = await Directory.systemTemp.createTemp('hook_detection_test-');
      try {
        final dartTool = Directory(p.join(tmp.path, '.dart_tool'))
          ..createSync(recursive: true);
        File(
          p.join(dartTool.path, 'package_config.json'),
        ).writeAsStringSync('{');

        await expectLater(
          nativeHookDiscovery().hasBuildHooks(tmp.path),
          throwsA(
            isA<FlutterBuildError>().having(
              (error) => error.message,
              'message',
              contains('malformed JSON'),
            ),
          ),
        );
      } finally {
        await tmp.delete(recursive: true);
      }
    },
  );

  test(
    testOn: '!windows',
    'detects native hooks from an ancestor workspace config',
    () async {
      final tmp = await Directory.systemTemp.createTemp('workspace_hooks-');
      try {
        final app = Directory(p.join(tmp.path, 'apps', 'example'))
          ..createSync(recursive: true);
        final hook = File(
          p.join(tmp.path, 'dependency with spaces', 'hook', 'build.dart'),
        )..createSync(recursive: true);
        final config = File(
          p.join(tmp.path, '.dart_tool', 'package_config.json'),
        )..createSync(recursive: true);
        config.writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {
                'name': 'native_dependency',
                'rootUri': '../dependency%20with%20spaces/',
                'packageUri': 'lib/',
              },
            ],
          }),
        );

        expect(await nativeHookDiscovery().hasBuildHooks(app.path), isTrue);
        hook.deleteSync();
        expect(await nativeHookDiscovery().hasBuildHooks(app.path), isFalse);

        hook.createSync();
        File(p.join(app.path, '.dart_tool', 'package_config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync('{"configVersion":2,"packages":[]}');
        expect(await nativeHookDiscovery().hasBuildHooks(app.path), isFalse);
      } finally {
        await tmp.delete(recursive: true);
      }
    },
  );

  test(
    testOn: '!windows',
    'normalizes native asset framework install names',
    () async {
      final tmp = await Directory.systemTemp.createTemp(
        'native_framework_test-',
      );
      try {
        final asset = Directory(p.join(tmp.path, 'Asset.framework'))
          ..createSync();
        final dependency = Directory(p.join(tmp.path, 'Dependency.framework'))
          ..createSync();
        final assetBytes = _dylibMachO([
          '/very/long/native/assets/path/libAsset.dylib',
          '/very/long/native/assets/path/libDependency.dylib',
        ]);
        final dependencyBytes = _dylibMachO([
          '/very/long/native/assets/path/libDependency.dylib',
        ]);

        File(p.join(asset.path, 'Asset')).writeAsBytesSync(assetBytes);
        File(
          p.join(dependency.path, 'Dependency'),
        ).writeAsBytesSync(dependencyBytes);

        await frameworks.normalize([asset.path, dependency.path]);

        expect(
          _dylibNames(File(p.join(asset.path, 'Asset')).readAsBytesSync()),
          [
            '@rpath/Asset.framework/Asset',
            '@rpath/Dependency.framework/Dependency',
          ],
        );
        expect(
          _dylibNames(
            File(p.join(dependency.path, 'Dependency')).readAsBytesSync(),
          ),
          ['@rpath/Dependency.framework/Dependency'],
        );
      } finally {
        await tmp.delete(recursive: true);
      }
    },
  );

  test(
    testOn: '!windows',

    'mapped collection staging normalization and alignment preserve source outputs',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'mapped-native-frameworks-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final mapped = FixtureMappedFileSystem(root);
      final host = LinuxHost(fileSystem: mapped);
      final service = nativeFrameworkService(
        fixtureRunner(host, log: fixtureLog()),
      );
      const output = '/xcross-native-framework-fixture/assemble';
      const project = '/xcross-native-framework-fixture/project';
      final paths = host.paths.context;
      final asset = paths.join(output, 'native_assets', 'Asset.framework');
      final table = paths.join(
        project,
        'build',
        'native_assets',
        'ios',
        'Table.framework',
      );
      final assetBinary = mapped.file(paths.join(asset, 'Asset'))
        ..createSync(recursive: true);
      final tableBinary = mapped.file(paths.join(table, 'Table'))
        ..createSync(recursive: true);
      final assetBytes = _dylibMachO([
        '/very/long/native/assets/path/libAsset.dylib',
      ]);
      final tableBytes = buildMachO(
        indirectCount: 3,
        strings: stringTable('_hello', padding: 8),
      );
      assetBinary.writeAsBytesSync(assetBytes);
      tableBinary.writeAsBytesSync(tableBytes);
      final stale =
          mapped.file(
              paths.join(
                project,
                'build',
                'native_assets',
                'ios',
                'Asset.framework',
                'Asset',
              ),
            )
            ..createSync(recursive: true)
            ..writeAsStringSync('stale');
      final selected = service.collect(
        jsonEncode({
          'native-assets': {
            'ios_arm64': {
              'asset': ['relative', 'Asset.framework/Asset'],
              'table': ['relative', 'Table.framework/Table'],
            },
          },
        }),
        output,
        projectRoot: project,
      );
      expect(selected, [asset, table]);
      final staged = await service.stage(selected, output);
      expect(staged, [
        paths.join(output, 'xcross_staged_frameworks', 'Asset.framework'),
        paths.join(output, 'xcross_staged_frameworks', 'Table.framework'),
      ]);
      await service.normalize(staged);
      await service.align(staged);
      expect(Directory(output).existsSync(), isFalse);
      await expectLater(
        File(paths.join(staged[0], 'Asset')).readAsBytes(),
        throwsA(isA<FileSystemException>()),
      );
      final stagedAsset = mapped.file(paths.join(staged[0], 'Asset'));
      final stagedTable = mapped.file(paths.join(staged[1], 'Table'));
      expect(_dylibNames(stagedAsset.readAsBytesSync()), [
        '@rpath/Asset.framework/Asset',
      ]);
      expect(readSymtab(stagedTable.readAsBytesSync()).offset % 8, 0);
      expect(stagedTable.lengthSync(), tableBytes.length);
      expect(assetBinary.readAsBytesSync(), assetBytes);
      expect(tableBinary.readAsBytesSync(), tableBytes);
      expect(stale.readAsStringSync(), 'stale');
      final unchangedTime = DateTime.utc(2000);
      stagedAsset.setLastModifiedSync(unchangedTime);
      stagedTable.setLastModifiedSync(unchangedTime);
      await service.normalize(staged);
      await service.align(staged);
      expect(stagedAsset.lastModifiedSync().toUtc(), unchangedTime);
      expect(stagedTable.lastModifiedSync().toUtc(), unchangedTime);
      expect(
        mapped.touched,
        containsAll([
          paths.join(staged[0], 'Asset'),
          paths.join(staged[1], 'Table'),
        ]),
      );
      expect(
        service.collect(
          jsonEncode({
            'native-assets': {'ios_arm64': <String, Object?>{}},
          }),
          output,
        ),
        isEmpty,
      );
      final collision = mapped.directory(
        '/xcross-native-framework-fixture/other/Asset.framework',
      )..createSync(recursive: true);
      expect(
        () => service.collect(
          jsonEncode({
            'native-assets': {
              'ios_arm64': {
                'first': ['absolute', paths.join(asset, 'Asset')],
                'second': [
                  'absolute',
                  paths.join(
                    '/xcross-native-framework-fixture/other/Asset.framework',
                    'Asset',
                  ),
                ],
              },
            },
          }),
          output,
        ),
        throwsA(
          isA<FlutterBuildError>().having(
            (e) => e.message,
            'message',
            contains('name collision'),
          ),
        ),
      );
      expect(collision.existsSync(), isTrue);
    },
  );

  for (final outcome in [
    'success',
    'nonzero-exit',
    'missing-output',
    'start-failure',
  ]) {
    test(
      testOn: '!windows',

      'mapped thinning preserves hooks and cleans scratch on $outcome',
      () async {
        final root = Directory.systemTemp.createTempSync(
          'mapped-native-thinning-',
        );
        addTearDown(() => root.deleteSync(recursive: true));
        final mapped = FixtureMappedFileSystem(root);
        final processes = FrameworkLipoProcesses(fileSystem: mapped);
        final startFailure = Exception('lipo fixture start failure');
        if (outcome == 'nonzero-exit') processes.code = 23;
        if (outcome == 'missing-output') processes.produceOutput = false;
        if (outcome == 'start-failure') processes.startFailure = startFailure;
        final host = LinuxHost(fileSystem: mapped, processes: processes);
        final runner = fixtureRunner(
          host,
          log: fixtureLog(),
          configuration: ProcessConfiguration(
            normalizedTools: const {'lipo': '/configured/llvm-lipo'},
            effectiveChildEnvironment: const {'SELECTED_ENV': 'fixture'},
          ),
        );
        final service = nativeFrameworkService(runner);
        const output = '/xcross-native-thin-fixture/assemble';
        const source = '$output/native_assets/Fat.framework';
        final original = mapped.file('$source/Fat')
          ..createSync(recursive: true);
        final fat = <int>[0xca, 0xfe, 0xba, 0xbe, 1, 2, 3, 4];
        original.writeAsBytesSync(fat);
        final staged = await service.stage([source], output);
        final binary = '${staged.single}/Fat';
        final result = service.thin(staged, lipo: 'lipo');
        if (outcome == 'success') {
          await result;
          expect(mapped.file(binary).readAsBytesSync(), processes.output);
          await service.thin(staged, lipo: 'lipo');
          expect(processes.calls, hasLength(1));
        } else {
          await expectLater(
            result,
            outcome == 'start-failure'
                ? throwsA(same(startFailure))
                : throwsA(isA<Exception>()),
          );
          expect(mapped.file(binary).readAsBytesSync(), fat);
        }
        expect(processes.calls.single.$1, '/configured/llvm-lipo');
        expect(processes.calls.single.$2, [
          '-thin',
          'arm64',
          binary,
          '-output',
          '$binary.xcross-thin',
        ]);
        expect(processes.calls.single.$3?['SELECTED_ENV'], 'fixture');
        expect(mapped.file('$binary.xcross-thin').existsSync(), isFalse);
        expect(original.readAsBytesSync(), fat);
        expect(mapped.touched, containsAll([binary, '$binary.xcross-thin']));
      },
    );
  }

  test('embedded frameworks are thinned only when universal', () async {
    final root = Directory.systemTemp.createTempSync('embedded-thinning-');
    addTearDown(() => root.deleteSync(recursive: true));
    final mapped = FixtureMappedFileSystem(root);
    final processes = FrameworkLipoProcesses(fileSystem: mapped);
    final host = LinuxHost(fileSystem: mapped, processes: processes);
    final runner = fixtureRunner(
      host,
      log: fixtureLog(),
      configuration: ProcessConfiguration(
        normalizedTools: const {'lipo': '/configured/llvm-lipo'},
        effectiveChildEnvironment: const {},
      ),
    );
    final service = nativeFrameworkService(runner);
    const frameworks = '/xcross-embedded-thin-fixture/Frameworks';
    final universal = mapped.file('$frameworks/Universal.framework/Universal')
      ..createSync(recursive: true)
      ..writeAsBytesSync([0xca, 0xfe, 0xba, 0xbe, 1, 2, 3, 4]);
    final single = mapped.file('$frameworks/Single.framework/Single')
      ..createSync(recursive: true)
      ..writeAsBytesSync([0xcf, 0xfa, 0xed, 0xfe, 7]);
    var lookups = 0;

    await service.thinEmbedded(
      ['$frameworks/Single.framework'],
      lipo: () async {
        lookups++;
        return 'lipo';
      },
    );
    expect(lookups, 0);
    expect(processes.calls, isEmpty);

    await service.thinEmbedded(
      ['$frameworks/Universal.framework', '$frameworks/Single.framework'],
      lipo: () async {
        lookups++;
        return 'lipo';
      },
    );
    expect(lookups, 1);
    expect(processes.calls, hasLength(1));
    expect(processes.calls.single.$2.take(3).toList(), [
      '-thin',
      'arm64',
      '$frameworks/Universal.framework/Universal',
    ]);
    expect(universal.readAsBytesSync(), processes.output);
    expect(single.readAsBytesSync(), [0xcf, 0xfa, 0xed, 0xfe, 7]);
  });

  test(testOn: '!windows', 'detects all FAT Mach-O binaries', () async {
    final tmp = await Directory.systemTemp.createTemp('fat_macho_test-');
    try {
      for (final magic in const <List<int>>[
        [0xca, 0xfe, 0xba, 0xbe],
        [0xbe, 0xba, 0xfe, 0xca],
        [0xca, 0xfe, 0xba, 0xbf],
        [0xbf, 0xba, 0xfe, 0xca],
      ]) {
        final fat = File(p.join(tmp.path, 'fat-${magic.first}'))
          ..writeAsBytesSync(magic);
        expect(await frameworks.isFat(fat.path), isTrue);
      }
      final thin = File(p.join(tmp.path, 'thin'))
        ..writeAsBytesSync([0xcf, 0xfa, 0xed, 0xfe]);
      expect(await frameworks.isFat(thin.path), isFalse);
    } finally {
      await tmp.delete(recursive: true);
    }
  });
}

Uint8List _dylibMachO(List<String> names) {
  final encoded = names.map(utf8.encode).toList();
  final sizes = [for (final name in encoded) (24 + name.length + 1 + 7) & ~7];
  final commandsSize = sizes.fold(0, (sum, size) => sum + size);
  final bytes = Uint8List(32 + commandsSize);
  final data = ByteData.sublistView(bytes)
    ..setUint32(0, 0xfeedfacf, Endian.little)
    ..setUint32(16, names.length, Endian.little)
    ..setUint32(20, commandsSize, Endian.little);
  var offset = 32;
  for (var index = 0; index < names.length; index++) {
    data
      ..setUint32(offset, index == 0 ? 0x0d : 0x0c, Endian.little)
      ..setUint32(offset + 4, sizes[index], Endian.little)
      ..setUint32(offset + 8, 24, Endian.little);
    bytes.setRange(
      offset + 24,
      offset + 24 + encoded[index].length,
      encoded[index],
    );
    offset += sizes[index];
  }
  return bytes;
}

List<String> _dylibNames(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final count = data.getUint32(16, Endian.little);
  final names = <String>[];
  var offset = 32;
  for (var index = 0; index < count; index++) {
    final size = data.getUint32(offset + 4, Endian.little);
    final start = offset + data.getUint32(offset + 8, Endian.little);
    var end = start;
    while (bytes[end] != 0) {
      end++;
    }
    names.add(utf8.decode(bytes.sublist(start, end)));
    offset += size;
  }
  return names;
}

@internal
NativeAssetsHookDiscovery nativeHookDiscovery() {
  final host = LinuxHost(
    currentDirectory: Directory.current.path,
    temporaryDirectory: Directory.systemTemp.path,
  );
  return NativeAssetsHookDiscovery(
    fileSystem: host.fileSystem,
    paths: host.paths.context,
    packageConfigs: PackageConfigResolver(
      fileSystem: host.fileSystem,
      paths: host.paths.context,
    ),
  );
}
