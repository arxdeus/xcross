import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/sdk_install.dart';
import 'package:xcross/src/flutter/build/flutter_pack_operation.dart';
import 'package:xcross/src/flutter/build/flutter_packer.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_gate_evidence.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/flutter/constants.dart';
import 'package:xcross/src/flutter/errors.dart';

/// Resolves a path under `lib/src/flutter/` without depending on the working
/// directory the suite happens to be launched from.
String _flutterSrc(String relative) => File.fromUri(
  Isolate.resolvePackageUriSync(
    Uri.parse('package:xcross/src/flutter/$relative'),
  )!,
).parent.path;

String _read(String relative) =>
    File('${_flutterSrc(relative)}/${p.basename(relative)}').readAsStringSync();

Future<void> _deleteTemp(Directory directory) async {
  try {
    await directory.delete(recursive: true);
  } on PathNotFoundException {
    if (directory.existsSync()) rethrow;
  }
}

void main() {
  test(
    'resolves explicit and configured Flutter roots before environment roots',
    () async {
      addTearDown(FlutterPacker.resetFlutterRootOverride);
      FlutterPacker.configureFlutterRootOverride('/configured/flutter');

      expect(
        await FlutterPacker.resolveFlutterRoot(
          projectRoot: Directory.systemTemp.path,
          root: '/explicit/flutter',
        ),
        '/explicit/flutter',
      );
      expect(
        await FlutterPacker.resolveFlutterRoot(
          projectRoot: Directory.systemTemp.path,
        ),
        '/configured/flutter',
      );
    },
  );

  test(
    'configured Flutter environment wins with legacy fallbacks enabled',
    () async {
      addTearDown(FlutterPacker.resetFlutterRootOverride);
      FlutterPacker.configureFlutterResolution(
        environmentRoot: '/configured/environment/flutter',
        declarative: false,
      );

      expect(
        await FlutterPacker.resolveFlutterRoot(
          projectRoot: Directory.systemTemp.path,
        ),
        '/configured/environment/flutter',
      );
    },
  );

  test(
    'declarative Flutter resolution uses configured environment then FVM',
    () async {
      final temp = Directory.systemTemp.createTempSync('flutter-resolution-');
      addTearDown(() {
        FlutterPacker.resetFlutterRootOverride();
        temp.deleteSync(recursive: true);
      });
      FlutterPacker.configureFlutterResolution(
        environmentRoot: '/configured/environment/flutter',
        declarative: true,
      );
      expect(
        await FlutterPacker.resolveFlutterRoot(projectRoot: temp.path),
        '/configured/environment/flutter',
      );

      final sdk = Directory(p.join(temp.path, 'sdk'))..createSync();
      Directory(p.join(temp.path, '.fvm')).createSync();
      Link(p.join(temp.path, '.fvm', 'flutter_sdk')).createSync(sdk.path);
      FlutterPacker.configureFlutterResolution(declarative: true);
      expect(
        await FlutterPacker.resolveFlutterRoot(projectRoot: temp.path),
        sdk.resolveSymbolicLinksSync(),
      );
    },
  );

  test(
    'declarative Flutter resolution uses configured tool after FVM',
    () async {
      addTearDown(FlutterPacker.resetFlutterRootOverride);
      FlutterPacker.configureFlutterResolution(
        tool: '/configured/flutter/bin/flutter',
        declarative: true,
      );
      expect(
        await FlutterPacker.resolveFlutterRoot(
          projectRoot: p.join(Directory.systemTemp.path, 'missing-project'),
        ),
        '/configured/flutter',
      );
    },
  );

  test('Windows no longer rejects native iOS plugins', () {
    final source = _read('build/flutter_packer.dart');

    expect(
      source,
      isNot(contains('Native iOS Flutter plugins are not yet supported')),
    );
    expect(source, isNot(contains('Platform.isWindows && nativePlugins')));
    expect(source, contains('if (plugin.usesSwiftPackageManager)'));
    expect(source, contains('else if (plugin.usesCocoaPods)'));
  });

  test('keeps independent artifact capabilities disabled by default', () {
    final source = _read('build/flutter_packer.dart');

    expect(source, contains('this.swiftPmArtifactJunctionCapability = false'));
    expect(
      source,
      contains('this.packageLocalArtifactJunctionCapability = false'),
    );
    expect(source, contains('artifactJunctionCapabilityResolver'));
    expect(
      source,
      contains('swiftPmArtifact: swiftPmArtifactJunctionCapability'),
    );
    expect(
      source,
      contains('packageLocalArtifact: packageLocalArtifactJunctionCapability'),
    );
  });

  test('missing Windows Darwin SDK produces install guidance', () async {
    final workspace = SwiftPmWorkspace.forProject(
      Directory.systemTemp.path,
      environment: {'XCROSS_CACHE_DIR': Directory.systemTemp.path},
    );

    await expectLater(
      FlutterPackOperation.resolveArtifactJunctionCapabilities(
        workspace: workspace,
        currentDarwinSdk: () => null,
        windows: true,
      ),
      throwsA(
        isA<FlutterBuildError>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('Darwin Swift SDK not found'),
            contains('xcross sdk install'),
          ),
        ),
      ),
    );
  });

  test('ambient environment cannot enable production junctions', () async {
    expect(
      await FlutterPackOperation.artifactJunctionCapabilities(
        evidenceRoot: p.join(Directory.systemTemp.path, 'missing-evidence'),
        platformIdentity: 'windows-x64',
        toolchainIdentity: 'swift-6.3.3',
        sdkIdentity: 'sdk-a',
        environment: const {
          'XCROSS_PACKAGE_LOCAL_ARTIFACT_JUNCTION': '1',
          'XCROSS_SWIFTPM_ARTIFACT_JUNCTION': '1',
        },
      ),
      (swiftPmArtifact: false, packageLocalArtifact: false),
    );
  });

  Future<Map<String, Object?>?> testBinding({
    required SwiftPmGateMode mode,
    required String root,
    required String platformIdentity,
    required String toolchainIdentity,
    required String sdkIdentity,
  }) async => {
    'formatVersion': 3,
    'gateImplementationVersion': 3,
    'extractorBuildVersion': 'xcross-1.3.1-swiftpm-gate-3',
    'mode': mode.name,
    'platform': platformIdentity,
    'toolchain': toolchainIdentity,
    'sdk': sdkIdentity,
    'volume': 'test-volume',
  };

  test('no prior evidence probes both modes and records successes', () async {
    final temp = await Directory.systemTemp.createTemp(
      'xcross-gate-first-use-',
    );
    try {
      final platform =
          '${Platform.operatingSystem}-${Platform.operatingSystemVersion}';
      final probed = <SwiftPmGateMode>[];
      final capabilities =
          await FlutterPackOperation.artifactJunctionCapabilities(
            evidenceRoot: temp.path,
            platformIdentity: platform,
            toolchainIdentity: 'first-use-toolchain',
            sdkIdentity: 'first-use-sdk',
            runtimeBinding: testBinding,
            probe:
                ({
                  required mode,
                  required root,
                  required toolchainIdentity,
                  required sdkIdentity,
                }) async {
                  probed.add(mode);
                  return true;
                },
          );

      expect(capabilities, (swiftPmArtifact: true, packageLocalArtifact: true));
      expect(probed, SwiftPmGateMode.values);
      expect(
        File(p.join(temp.path, 'swiftPmArtifact.evidence.json')).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(temp.path, 'packageLocalArtifact.evidence.json'),
        ).existsSync(),
        isTrue,
      );
    } finally {
      await _deleteTemp(temp);
    }
  });

  test('failed first-use probe remains disabled and is not recorded', () async {
    final temp = await Directory.systemTemp.createTemp('xcross-gate-failure-');
    try {
      final platform =
          '${Platform.operatingSystem}-${Platform.operatingSystemVersion}';
      var calls = 0;
      final evidence = SwiftPmGateEvidence(temp.path);
      for (var invocation = 0; invocation < 2; invocation++) {
        expect(
          await evidence.verifies(
            mode: SwiftPmGateMode.swiftPmArtifact,
            platformIdentity: platform,
            toolchainIdentity: 'failed-toolchain',
            sdkIdentity: 'failed-sdk',
            runtimeBinding: testBinding,
            probe:
                ({
                  required mode,
                  required root,
                  required toolchainIdentity,
                  required sdkIdentity,
                }) async {
                  calls++;
                  return false;
                },
          ),
          isFalse,
        );
      }
      expect(calls, 1);
      expect(
        File(p.join(temp.path, 'swiftPmArtifact.evidence.json')).existsSync(),
        isFalse,
      );
    } finally {
      await _deleteTemp(temp);
    }
  });

  test('executable identities produce independent evidence bindings', () async {
    final temp = await Directory.systemTemp.createTemp('xcross-gate-tools-');
    try {
      final evidence = SwiftPmGateEvidence(temp.path);
      final platform =
          '${Platform.operatingSystem}-${Platform.operatingSystemVersion}';
      var calls = 0;
      Future<bool> probe({
        required SwiftPmGateMode mode,
        required String root,
        required String toolchainIdentity,
        required String sdkIdentity,
      }) async {
        calls++;
        return true;
      }

      for (final identity in [
        '{"swift-package":{"path":"A/swift-package.exe","version":"6.3"},"swift-build":{"path":"A/swift-build.exe","version":"6.3"}}',
        '{"swift-package":{"path":"B/swift-package.exe","version":"6.3"},"swift-build":{"path":"A/swift-build.exe","version":"6.3"}}',
      ]) {
        expect(
          await evidence.verifies(
            mode: SwiftPmGateMode.swiftPmArtifact,
            platformIdentity: platform,
            toolchainIdentity: identity,
            sdkIdentity: 'tools-sdk',
            probe: probe,
            runtimeBinding: testBinding,
          ),
          isTrue,
        );
      }
      expect(calls, 2);
    } finally {
      await _deleteTemp(temp);
    }
  });
  test(
    'toolchain identity invokes a driver through its located name',
    () async {
      final temp = await Directory.systemTemp.createTemp('xcross-driver-name-');
      try {
        final driver = File(p.join(temp.path, 'swift-driver'))
          ..writeAsStringSync('driver');
        final swift = Link(p.join(temp.path, 'swift'))..createSync(driver.path);
        final swiftc = Link(p.join(temp.path, 'swiftc'))
          ..createSync(driver.path);
        final other = File(p.join(temp.path, 'tool'))
          ..writeAsStringSync('tool');
        final invoked = <String>[];

        final identity = await SdkInstall.swiftPmBuildToolchainIdentity(
          cCompilerPath: other.path,
          cxxCompilerPath: other.path,
          linkerPath: other.path,
          librarianPath: other.path,
          windows: false,
          locateTool: (name) async =>
              name == 'swift' ? swift.path : swiftc.path,
          runProcess: (executable, arguments) async {
            invoked.add(executable);
            return const CapturedProcess(0, 'Swift version 6.3\n', '');
          },
        );

        expect(invoked, [swift.path, swiftc.path]);
        expect(
          (identity['swift']! as Map<String, Object>)['path'],
          driver.resolveSymbolicLinksSync(),
        );
      } finally {
        await _deleteTemp(temp);
      }
    },
  );

  test('replacing each non-driver tool invalidates gate evidence', () async {
    final temp = await Directory.systemTemp.createTemp('xcross-gate-tools-');
    try {
      final tools = <String, File>{
        for (final name in const [
          'swift-package',
          'swift-build',
          'swiftc',
          'clang',
          'clang++',
          'ld64.lld',
          'librarian',
        ])
          name: File(p.join(temp.path, name))..writeAsStringSync('first-$name'),
      };
      Future<Map<String, Object>> identity() =>
          SdkInstall.swiftPmBuildToolchainIdentity(
            cCompilerPath: tools['clang']!.path,
            cxxCompilerPath: tools['clang++']!.path,
            linkerPath: tools['ld64.lld']!.path,
            librarianPath: tools['librarian']!.path,
            windows: true,
            locateTool: (name) async => tools[name]!.path,
            runProcess: (executable, arguments) async =>
                const CapturedProcess(0, 'Swift version 6.3\n', ''),
          );

      for (final name in const [
        'swiftc',
        'clang',
        'clang++',
        'ld64.lld',
        'librarian',
      ]) {
        final recorded = await identity();
        expect(await validSwiftPmGateToolchainIdentity(recorded), isTrue);
        tools[name]!.writeAsStringSync('replacement-$name-with-different-size');
        expect(
          await validSwiftPmGateToolchainIdentity(recorded),
          isFalse,
          reason: name,
        );
        tools[name]!.writeAsStringSync('first-$name');
      }
    } finally {
      await _deleteTemp(temp);
    }
  });

  test('valid evidence skips probe across simulated process reset', () async {
    final temp = await Directory.systemTemp.createTemp('xcross-gate-evidence-');
    try {
      final platform =
          '${Platform.operatingSystem}-${Platform.operatingSystemVersion}';
      var calls = 0;
      Future<bool> probe({
        required SwiftPmGateMode mode,
        required String root,
        required String toolchainIdentity,
        required String sdkIdentity,
      }) async {
        calls++;
        return true;
      }

      for (var process = 0; process < 2; process++) {
        expect(
          await SwiftPmGateEvidence(temp.path).verifies(
            mode: SwiftPmGateMode.packageLocalArtifact,
            platformIdentity: platform,
            toolchainIdentity: 'toolchain',
            sdkIdentity: 'sdk',
            probe: probe,
            runtimeBinding: testBinding,
          ),
          isTrue,
        );
      }
      expect(calls, 1);
    } finally {
      await _deleteTemp(temp);
    }
  });

  test('stale and forged evidence trigger the probe', () async {
    final temp = await Directory.systemTemp.createTemp('xcross-gate-forged-');
    try {
      final platform =
          '${Platform.operatingSystem}-${Platform.operatingSystemVersion}';
      var calls = 0;
      Future<bool> probe({
        required SwiftPmGateMode mode,
        required String root,
        required String toolchainIdentity,
        required String sdkIdentity,
      }) async {
        calls++;
        return true;
      }

      final evidence = SwiftPmGateEvidence(temp.path);
      expect(
        await evidence.verifies(
          mode: SwiftPmGateMode.swiftPmArtifact,
          platformIdentity: platform,
          toolchainIdentity: 'toolchain',
          sdkIdentity: 'sdk',
          probe: probe,
          runtimeBinding: testBinding,
        ),
        isTrue,
      );
      final file = File(p.join(temp.path, 'swiftPmArtifact.evidence.json'));
      final stale = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      stale['volume'] = 'other-volume';
      file.writeAsStringSync(jsonEncode(stale), flush: true);
      expect(
        await evidence.verifies(
          mode: SwiftPmGateMode.swiftPmArtifact,
          platformIdentity: platform,
          toolchainIdentity: 'toolchain',
          sdkIdentity: 'sdk',
          probe: probe,
          runtimeBinding: testBinding,
        ),
        isTrue,
      );
      final forged =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final proof = forged['proof']! as Map<String, Object?>;
      proof['resultDigest'] = '0' * 64;
      file.writeAsStringSync(jsonEncode(forged), flush: true);
      expect(
        await evidence.verifies(
          mode: SwiftPmGateMode.swiftPmArtifact,
          platformIdentity: platform,
          toolchainIdentity: 'toolchain',
          sdkIdentity: 'sdk',
          probe: probe,
          runtimeBinding: testBinding,
        ),
        isTrue,
      );
      expect(calls, 3);
    } finally {
      await _deleteTemp(temp);
    }
  });

  test('copies every SwiftPM dylib into Frameworks', () async {
    final tmp = await Directory.systemTemp.createTemp('flutter_packer_test-');
    try {
      final frameworks = Directory(p.join(tmp.path, 'Frameworks'))
        ..createSync();
      final aggregate = File(p.join(tmp.path, 'libAggregate.dylib'))
        ..writeAsStringSync('aggregate');
      final dependency = File(p.join(tmp.path, 'libDependency.dylib'))
        ..writeAsStringSync('dependency');

      await FlutterPacker.copyPluginLibraries([
        aggregate.path,
        dependency.path,
      ], frameworks.path);

      expect(
        File(
          p.join(frameworks.path, p.basename(aggregate.path)),
        ).readAsStringSync(),
        'aggregate',
      );
      expect(
        File(
          p.join(frameworks.path, p.basename(dependency.path)),
        ).readAsStringSync(),
        'dependency',
      );
    } finally {
      await _deleteTemp(tmp);
    }
  });

  test('copies native-asset frameworks recursively into Frameworks', () async {
    final tmp = await Directory.systemTemp.createTemp('native_framework_test-');
    try {
      final source = Directory(p.join(tmp.path, 'Foo.framework'))..createSync();
      File(p.join(source.path, 'Foo')).writeAsStringSync('binary');
      Directory(p.join(source.path, 'Resources')).createSync();
      File(
        p.join(source.path, 'Resources', 'Info.plist'),
      ).writeAsStringSync('plist');
      final destination = Directory(p.join(tmp.path, 'Frameworks'))
        ..createSync();

      await FlutterPacker.copyNativeAssetFrameworks([
        source.path,
      ], destination.path);

      expect(
        File(
          p.join(destination.path, 'Foo.framework', 'Foo'),
        ).readAsStringSync(),
        'binary',
      );
      expect(
        File(
          p.join(destination.path, 'Foo.framework', 'Resources', 'Info.plist'),
        ).readAsStringSync(),
        'plist',
      );
    } finally {
      await _deleteTemp(tmp);
    }
  });
  test('uses xcross build, temp, and DevFS names', () {
    final debugBundler = _read('build/flutter_debug_bundler.dart');
    final packOperation = _read('build/flutter_pack_operation.dart');
    final hotReload = _read('build/hot_reload_setup.dart');
    // Scanned as a directory, not a fixed filename: the incremental dill path
    // has already moved once (out of the deleted frontend_server_client.dart,
    // when frontend_server driving was extracted into the project-agnostic
    // package:frontend_server_kit) and naming a single file broke this test.
    final hotReloadLayer = Directory(
      _flutterSrc('hot_reload/source_watcher.dart'),
    ).listSync(recursive: true).whereType<File>().map((f) => f.path);
    expect(hotReloadLayer, isNotEmpty, reason: 'hot_reload sources not found');
    final hotReloadSources = hotReloadLayer
        .map(File.new)
        .map((f) => f.readAsStringSync())
        .join('\n');

    expect(debugBundler, contains("'xcross-flutter-debug'"));
    expect(
      debugBundler,
      isNot(contains("'NativeAssetsManifest.json'")),
      reason: 'the native-assets builder owns this manifest',
    );
    expect(debugBundler, contains("'xcross-flutter-stub-'"));
    expect(packOperation, contains("'xcross-ios'"));
    expect(hotReload, contains("'xcross-flutter-debug'"));
    expect(hotReloadSources, contains('build/xcross-flutter-debug'));
    expect(FlutterDeviceConstants.devFsName, 'xcross');
  });
}
