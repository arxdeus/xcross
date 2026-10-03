import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/host/linux/flutter/native_host_tools.dart';
import 'package:xcross/src/host/macos/flutter/native_host_tools.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';
import 'package:xcross/src/host/windows/flutter/native_host_tools.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';
import 'package:xcross/src/target/simulator/flutter/simulator_flutter_target.dart';

void main() {
  late Directory temp;
  late String flutterRoot;
  late String cacheRoot;
  final host = LinuxHost(architecture: 'arm64');
  final hostTools = LinuxNativeHostTools(host, ProcessRunner(host));
  final policy = IPhoneFlutterTarget(IPhoneTarget(host));
  IosEngineCache<LinuxHost> cache() => IosEngineCache(
    targetPolicy: policy,
    hostTools: hostTools,
    flutterRoot: flutterRoot,
    cacheRoot: cacheRoot,
  );
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('engine-cache-unit-');
    flutterRoot = p.join(temp.path, 'flutter');
    cacheRoot = p.join(temp.path, 'cache');
    final stamp = File(
      p.join(flutterRoot, 'bin', 'internal', 'engine.version'),
    );
    await stamp.create(recursive: true);
    await stamp.writeAsString('engine-hash');
  });
  tearDown(() => temp.delete(recursive: true));
  test('selects simulator slices without falling back to device engine', () {
    final framework = p.join(temp.path, 'Flutter.xcframework');
    Directory(
      p.join(framework, 'ios-arm64', 'Flutter.framework'),
    ).createSync(recursive: true);
    final simulator = IosEngineCache(
      targetPolicy: SimulatorFlutterTarget(SimulatorTarget(host)),
      hostTools: hostTools,
      flutterRoot: flutterRoot,
    );
    expect(cache().flutterSlice(framework), p.join(framework, 'ios-arm64'));
    expect(
      () => simulator.flutterSlice(framework),
      throwsA(isA<FlutterBuildError>()),
    );
    for (final identifier in [
      'ios-arm64-simulator',
      'ios-arm64_x86_64-simulator',
    ]) {
      Directory(
        p.join(framework, identifier, 'Flutter.framework'),
      ).createSync(recursive: true);
      expect(simulator.flutterSlice(framework), p.join(framework, identifier));
    }
  });
  final macArm = MacOSHost(architecture: 'arm64');
  final macX64 = MacOSHost(architecture: 'x64');
  final linuxX64 = LinuxHost(architecture: 'x64');
  final windows = WindowsHost(architecture: 'x64', paths: PosixPaths());
  for (final (tools, targetPolicy, artifact, canonical)
      in <(NativeHostTools, FlutterTargetBuildPolicy, String, String)>[
        (hostTools, policy, 'linux-arm64', 'linux-arm64'),
        (
          LinuxNativeHostTools(linuxX64, ProcessRunner(linuxX64)),
          IPhoneFlutterTarget(IPhoneTarget(linuxX64)),
          'linux-x64',
          'linux-x64',
        ),
        (
          MacOSNativeHostTools(macArm, ProcessRunner(macArm)),
          IPhoneFlutterTarget(IPhoneTarget(macArm)),
          'darwin-arm64',
          'darwin-x64',
        ),
        (
          MacOSNativeHostTools(macX64, ProcessRunner(macX64)),
          IPhoneFlutterTarget(IPhoneTarget(macX64)),
          'darwin-x64',
          'darwin-x64',
        ),
        (
          WindowsNativeHostTools(windows, ProcessRunner(windows)),
          IPhoneFlutterTarget(IPhoneTarget(windows)),
          'windows-x64',
          'windows-x64',
        ),
      ]) {
    test(
      '$artifact preserves separate download and canonical SDK cache names',
      () {
        final engine = IosEngineCache(
          targetPolicy: targetPolicy,
          hostTools: tools,
          flutterRoot: flutterRoot,
          cacheRoot: cacheRoot,
        );
        expect(engine.hostArtifactPlatform, artifact);
        expect(engine.hostEngineCacheDirectory, canonical);
        expect(
          engine.hostArtifactsUrl,
          'https://storage.googleapis.com/flutter_infra_release/flutter/engine-hash/$artifact/artifacts.zip',
        );
        expect(p.basename(p.dirname(engine.vmSnapshotData)), artifact);
        final sdkHost = p.join(
          flutterRoot,
          'bin',
          'cache',
          'artifacts',
          'engine',
          canonical,
        );
        Directory(sdkHost).createSync(recursive: true);
        for (final name in [
          'vm_isolate_snapshot.bin',
          'isolate_snapshot.bin',
        ]) {
          File(p.join(sdkHost, name)).writeAsStringSync('snapshot');
        }
        expect(
          engine.vmSnapshotData,
          p.join(sdkHost, 'vm_isolate_snapshot.bin'),
        );
        expect(
          engine.isolateSnapshotData,
          p.join(sdkHost, 'isolate_snapshot.bin'),
        );
      },
    );
  }
  test('rejects unsupported host architectures early', () {
    final unsupported = WindowsHost(architecture: 'arm64');
    expect(
      () => IosEngineCache(
        targetPolicy: IPhoneFlutterTarget(IPhoneTarget(unsupported)),
        hostTools: WindowsNativeHostTools(
          unsupported,
          ProcessRunner(unsupported),
        ),
        flutterRoot: flutterRoot,
      ),
      throwsA(isA<FlutterBuildError>()),
    );
    final arm = LinuxHost(architecture: 'arm');
    expect(
      () => IosEngineCache(
        targetPolicy: IPhoneFlutterTarget(IPhoneTarget(arm)),
        hostTools: LinuxNativeHostTools(arm, ProcessRunner(arm)),
        flutterRoot: flutterRoot,
      ),
      throwsA(isA<FlutterBuildError>()),
    );
  });
  test('does not reuse Linux x64 artifacts for ARM64', () {
    final wrong = p.join(
      flutterRoot,
      'bin',
      'cache',
      'artifacts',
      'engine',
      'linux-x64',
    );
    Directory(wrong).createSync(recursive: true);
    for (final name in ['vm_isolate_snapshot.bin', 'isolate_snapshot.bin']) {
      File(p.join(wrong, name)).writeAsStringSync('x64');
    }
    expect(cache().vmSnapshotData, startsWith(cacheRoot));
    expect(p.basename(p.dirname(cache().vmSnapshotData)), 'linux-arm64');
  });
  test('prefers SDK artifacts, otherwise uses explicit user cache', () {
    final engine = cache();
    expect(
      engine.flutterXcframework,
      p.join(
        cacheRoot,
        'engine-hash',
        'artifacts',
        'engine',
        'ios',
        'Flutter.xcframework',
      ),
    );
    final sdk = p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'engine');
    Directory(
      p.join(sdk, 'ios', 'Flutter.xcframework'),
    ).createSync(recursive: true);
    Directory(
      p.join(sdk, 'common', 'flutter_patched_sdk'),
    ).createSync(recursive: true);
    expect(
      engine.flutterXcframework,
      p.join(sdk, 'ios', 'Flutter.xcframework'),
    );
    expect(engine.patchedSdkRoot, p.join(sdk, 'common', 'flutter_patched_sdk'));
  });
}
