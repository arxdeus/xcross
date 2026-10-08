import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_capabilities.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_identity.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_evidence.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_mode.dart';
import 'package:xcross/src/shared/sdk/sdk_build_identity.dart';

import 'swiftpm_test_context.dart';

final _runtime = testSwiftPmRuntime();
final _windowsRuntime = testWindowsSwiftPmRuntime();
Future<void> _deleteTemp(Directory directory) async {
  if (directory.existsSync()) await directory.delete(recursive: true);
}

@internal
final class MutableSwiftPmArtifactIdentities
    implements SwiftPmArtifactIdentities {
  String sdk = '{"revision":"sdk-a"}';
  String toolchain = '{"revision":"tool-a"}';
  int calls = 0;
  @override
  Future<SwiftPmArtifactIdentity> resolve() async {
    calls++;
    return SwiftPmArtifactIdentity(
      platform: 'test-platform',
      toolchain: toolchain,
      sdk: sdk,
    );
  }
}

void main() {
  test('missing Windows Darwin SDK produces install guidance', () async {
    final workspace = SwiftPmWorkspace.forProject(
      policy: _windowsRuntime.targetPolicy,
      Directory.systemTemp.path,
      environment: {'XCROSS_CACHE_DIR': Directory.systemTemp.path},
    );

    await expectLater(
      _windowsRuntime.artifactCapabilities.resolveArtifactJunctionCapabilities(
        workspace: workspace,
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
      await _runtime.artifactCapabilities.artifactJunctionCapabilities(
        evidenceRoot: p.join(Directory.systemTemp.path, 'missing-evidence'),
        platformIdentity: 'test-platform',
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
      const platform = 'test-platform';
      final probed = <SwiftPmGateMode>[];
      final capabilities = await _runtime.artifactCapabilities
          .artifactJunctionCapabilities(
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
      const platform = 'test-platform';
      var calls = 0;
      final evidence = SwiftPmGateEvidence(
        temp.path,
        repository: _runtime.sdkRepository,
        platform: _runtime.gatePlatform,
        platformIdentity: _runtime.sdkIdentity.platformIdentity,
        fileSystem: _runtime.artifactFileSystem,
      );
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
      final evidence = SwiftPmGateEvidence(
        temp.path,
        repository: _runtime.sdkRepository,
        platform: _runtime.gatePlatform,
        platformIdentity: _runtime.sdkIdentity.platformIdentity,
        fileSystem: _runtime.artifactFileSystem,
      );
      const platform = 'test-platform';
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

        final identity =
            await SdkBuildIdentity<MacOSHost>(
              _runtime.runner,
              _runtime.sdkRepository,
              const ['swift', 'swiftc'],
              const [],
            ).swiftPmBuildToolchainIdentity(
              cCompilerPath: other.path,
              cxxCompilerPath: other.path,
              linkerPath: other.path,
              librarianPath: other.path,
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
          SdkBuildIdentity<MacOSHost>(
            _runtime.runner,
            _runtime.sdkRepository,
            const ['swift-package', 'swift-build', 'swiftc'],
            const [],
          ).swiftPmBuildToolchainIdentity(
            cCompilerPath: tools['clang']!.path,
            cxxCompilerPath: tools['clang++']!.path,
            linkerPath: tools['ld64.lld']!.path,
            librarianPath: tools['librarian']!.path,
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
        expect(
          await validSwiftPmGateToolchainIdentity(
            recorded,
            fileSystem: _runtime.artifactFileSystem,
          ),
          isTrue,
        );
        tools[name]!.writeAsStringSync('replacement-$name-with-different-size');
        expect(
          await validSwiftPmGateToolchainIdentity(
            recorded,
            fileSystem: _runtime.artifactFileSystem,
          ),
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
      const platform = 'test-platform';
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
          await SwiftPmGateEvidence(
            temp.path,
            repository: _runtime.sdkRepository,
            platform: _runtime.gatePlatform,
            platformIdentity: _runtime.sdkIdentity.platformIdentity,
            fileSystem: _runtime.artifactFileSystem,
          ).verifies(
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
      const platform = 'test-platform';
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

      final evidence = SwiftPmGateEvidence(
        temp.path,
        repository: _runtime.sdkRepository,
        platform: _runtime.gatePlatform,
        platformIdentity: _runtime.sdkIdentity.platformIdentity,
        fileSystem: _runtime.artifactFileSystem,
      );
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
  test(
    'public resolver refreshes SDK and tool identities and validates live volume despite cached success',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'xcross-public-capabilities-',
      );
      final identities = MutableSwiftPmArtifactIdentities();
      var volume = 'first-volume';
      var allowProbe = true;
      var probes = 0;
      final capabilities = SwiftPmArtifactCapabilities(
        paths: _runtime.host.paths,
        fileSystem: _runtime.artifactFileSystem,
        repository: _runtime.sdkRepository,
        platform: _runtime.gatePlatform,
        identities: identities,
        probe:
            ({
              required mode,
              required root,
              required toolchainIdentity,
              required sdkIdentity,
            }) async {
              probes++;
              return allowProbe;
            },
        runtimeBinding:
            ({
              required mode,
              required root,
              required platformIdentity,
              required toolchainIdentity,
              required sdkIdentity,
            }) async {
              if (sdkIdentity == '{}') return null;
              return {
                ...?await testBinding(
                  mode: mode,
                  root: root,
                  platformIdentity: platformIdentity,
                  toolchainIdentity: toolchainIdentity,
                  sdkIdentity: sdkIdentity,
                ),
                'volume': volume,
              };
            },
      );
      final workspace = SwiftPmWorkspace.forProject(
        root.path,
        policy: _runtime.targetPolicy,
        environment: {'XCROSS_CACHE_DIR': root.path},
      );
      try {
        expect(
          await capabilities.resolveArtifactJunctionCapabilities(
            workspace: workspace,
          ),
          (swiftPmArtifact: true, packageLocalArtifact: true),
        );
        expect(
          await capabilities.resolveArtifactJunctionCapabilities(
            workspace: workspace,
          ),
          (swiftPmArtifact: true, packageLocalArtifact: true),
        );
        expect(probes, 2);
        identities.sdk = '{"revision":"sdk-b"}';
        expect(
          await capabilities.resolveArtifactJunctionCapabilities(
            workspace: workspace,
          ),
          (swiftPmArtifact: true, packageLocalArtifact: true),
        );
        expect(probes, 4);
        identities.toolchain = '{"revision":"tool-b"}';
        expect(
          await capabilities.resolveArtifactJunctionCapabilities(
            workspace: workspace,
          ),
          (swiftPmArtifact: true, packageLocalArtifact: true),
        );
        expect(probes, 6);
        identities.sdk = '{}';
        expect(
          await capabilities.resolveArtifactJunctionCapabilities(
            workspace: workspace,
          ),
          (swiftPmArtifact: false, packageLocalArtifact: false),
        );
        expect(probes, 6);
        identities.sdk = '{"revision":"sdk-b"}';
        volume = 'replacement-volume';
        allowProbe = false;
        expect(
          await capabilities.resolveArtifactJunctionCapabilities(
            workspace: workspace,
          ),
          (swiftPmArtifact: false, packageLocalArtifact: false),
        );
        expect(probes, 8);
        expect(identities.calls, 6);
        expect(
          (jsonDecode(File(workspace.gateCapabilityCache).readAsStringSync())
              as Map<String, dynamic>)['swiftPmArtifact'],
          isFalse,
        );
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );
}
