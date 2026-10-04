import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/host/linux/flutter/native_host_tools.dart';
import 'package:xcross/src/host/macos/flutter/native_host_tools.dart';
import 'package:xcross/src/host/shared/flutter/engine_archive_writer.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';
import 'package:xcross/src/host/windows/flutter/native_host_tools.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';
import 'package:xcross/src/target/simulator/flutter/simulator_flutter_target.dart';

void main() {
  final sinks = <IOSink>[];
  final subscriptions = <StreamSubscription<List<int>>>[];
  IOSink sink() {
    final controller = StreamController<List<int>>();
    subscriptions.add(controller.stream.listen((_) {}));
    final output = IOSink(controller.sink);
    sinks.add(output);
    return output;
  }

  tearDownAll(() async {
    for (final output in sinks) {
      await output.close();
    }
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  });
  test(
    'POSIX engine extraction retains executable mode and relative links',
    () async {
      final tmp = await Directory.systemTemp.createTemp(
        'engine-archive-posix-',
      );
      addTearDown(() => tmp.delete(recursive: true));
      final host = LinuxHost(architecture: 'arm64');
      final archive = Archive()
        ..add(
          ArchiveFile.bytes('tools/compiler', utf8.encode('clang'))
            ..mode = 0xa1ff
            ..symbolicLink = 'clang',
        )
        ..add(ArchiveFile.bytes('tools/clang', [1, 2, 3])..mode = 0x1ed)
        ..add(ArchiveFile.bytes('../escape', [4]))
        ..add(
          ArchiveFile.bytes('tools/escape', utf8.encode('../../escape'))
            ..mode = 0xa1ff
            ..symbolicLink = '../../escape',
        );
      final zip = File(p.join(tmp.path, 'engine.zip'))
        ..writeAsBytesSync(_unixZip(archive));
      final output = p.join(tmp.path, 'engine');
      await FlutterEngineArchiveWriter(host).extractZip(zip.path, output);
      expect(File(p.join(output, 'tools', 'clang')).readAsBytesSync(), [
        1,
        2,
        3,
      ]);
      expect(
        File(p.join(output, 'tools', 'clang')).statSync().mode & 0x1ff,
        0x1ed,
      );
      expect(Link(p.join(output, 'tools', 'compiler')).targetSync(), 'clang');
      expect(File(p.join(tmp.path, 'escape')).existsSync(), isFalse);
      expect(Link(p.join(output, 'tools', 'escape')).existsSync(), isFalse);
      await zip.delete();
    },
  );
  test(
    'Windows engine extraction materializes links after file entries',
    () async {
      final tmp = await Directory.systemTemp.createTemp(
        'engine-archive-windows-',
      );
      addTearDown(() => tmp.delete(recursive: true));
      final host = WindowsHost(architecture: 'x64', paths: PosixPaths());
      final archive = Archive()
        ..add(ArchiveFile.symlink('tools/alias', 'compiler'))
        ..add(ArchiveFile.symlink('tools/compiler', 'clang.exe'))
        ..add(ArchiveFile.bytes('tools/clang.exe', [1, 2, 3]));
      final output = p.join(tmp.path, 'engine');
      await FlutterEngineArchiveWriter(host).extract(archive, output);
      expect(File(p.join(output, 'tools', 'compiler')).readAsBytesSync(), [
        1,
        2,
        3,
      ]);
      expect(File(p.join(output, 'tools', 'alias')).readAsBytesSync(), [
        1,
        2,
        3,
      ]);
      expect(
        FileSystemEntity.typeSync(
          p.join(output, 'tools', 'alias'),
          followLinks: false,
        ),
        FileSystemEntityType.file,
      );
    },
  );

  late Directory temp;
  late String flutterRoot;
  late String cacheRoot;
  final host = LinuxHost(architecture: 'arm64');
  final hostTools = LinuxNativeHostTools(
    host,
    ProcessRunner(
      host,
      log: _log(),
      stdinStream: const Stream<List<int>>.empty(),
      stdoutSink: sink(),
      stderrSink: sink(),
    ),
  );
  final policy = IPhoneFlutterTarget(IPhoneTarget(host));
  IosEngineCache<LinuxHost> cache() => IosEngineCache(
    targetPolicy: policy,
    hostTools: hostTools,
    flutterRoot: flutterRoot,
    cacheRoot: cacheRoot,
    log: _log(),
    downloader: _downloader(),
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
  test(
    'Windows engine framework links resolve deferred ancestor aliases',
    () async {
      final tmp = await Directory.systemTemp.createTemp(
        'engine-framework-links-',
      );
      addTearDown(() => tmp.delete(recursive: true));
      final host = WindowsHost(architecture: 'x64', paths: PosixPaths());
      final archive = Archive()
        ..add(
          ArchiveFile.symlink(
            'Flutter.framework/Flutter',
            'Versions/Current/Flutter',
          ),
        )
        ..add(
          ArchiveFile.symlink(
            'Flutter.framework/Headers',
            'Versions/Current/Headers',
          ),
        )
        ..add(ArchiveFile.symlink('Flutter.framework/Versions/Current', 'A'))
        ..add(ArchiveFile.bytes('Flutter.framework/Versions/A/Flutter', [1, 2]))
        ..add(
          ArchiveFile.bytes('Flutter.framework/Versions/A/Headers/Flutter.h', [
            3,
          ]),
        );
      final output = p.join(tmp.path, 'engine');
      await FlutterEngineArchiveWriter(host).extract(archive, output);
      expect(
        File(p.join(output, 'Flutter.framework', 'Flutter')).readAsBytesSync(),
        [1, 2],
      );
      expect(
        File(
          p.join(output, 'Flutter.framework', 'Headers', 'Flutter.h'),
        ).readAsBytesSync(),
        [3],
      );
    },
  );
  test('selects simulator slices without falling back to device engine', () {
    final framework = p.join(temp.path, 'Flutter.xcframework');
    Directory(
      p.join(framework, 'ios-arm64', 'Flutter.framework'),
    ).createSync(recursive: true);
    final simulator = IosEngineCache(
      targetPolicy: SimulatorFlutterTarget(SimulatorTarget(host)),
      hostTools: hostTools,
      flutterRoot: flutterRoot,
      log: _log(),
      downloader: _downloader(),
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
          LinuxNativeHostTools(
            linuxX64,
            ProcessRunner(
              linuxX64,
              log: _log(),
              stdinStream: const Stream<List<int>>.empty(),
              stdoutSink: sink(),
              stderrSink: sink(),
            ),
          ),
          IPhoneFlutterTarget(IPhoneTarget(linuxX64)),
          'linux-x64',
          'linux-x64',
        ),
        (
          MacOSNativeHostTools(
            macArm,
            ProcessRunner(
              macArm,
              log: _log(),
              stdinStream: const Stream<List<int>>.empty(),
              stdoutSink: sink(),
              stderrSink: sink(),
            ),
          ),
          IPhoneFlutterTarget(IPhoneTarget(macArm)),
          'darwin-arm64',
          'darwin-x64',
        ),
        (
          MacOSNativeHostTools(
            macX64,
            ProcessRunner(
              macX64,
              log: _log(),
              stdinStream: const Stream<List<int>>.empty(),
              stdoutSink: sink(),
              stderrSink: sink(),
            ),
          ),
          IPhoneFlutterTarget(IPhoneTarget(macX64)),
          'darwin-x64',
          'darwin-x64',
        ),
        (
          WindowsNativeHostTools(
            windows,
            ProcessRunner(
              windows,
              log: _log(),
              stdinStream: const Stream<List<int>>.empty(),
              stdoutSink: sink(),
              stderrSink: sink(),
            ),
          ),
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
          log: _log(),
          downloader: _downloader(),
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
          ProcessRunner(
            unsupported,
            log: _log(),
            stdinStream: const Stream<List<int>>.empty(),
            stdoutSink: sink(),
            stderrSink: sink(),
          ),
        ),
        flutterRoot: flutterRoot,
        log: _log(),
        downloader: _downloader(),
      ),
      throwsA(isA<FlutterBuildError>()),
    );
    final arm = LinuxHost(architecture: 'arm');
    expect(
      () => IosEngineCache(
        targetPolicy: IPhoneFlutterTarget(IPhoneTarget(arm)),
        hostTools: LinuxNativeHostTools(
          arm,
          ProcessRunner(
            arm,
            log: _log(),
            stdinStream: const Stream<List<int>>.empty(),
            stdoutSink: sink(),
            stderrSink: sink(),
          ),
        ),
        flutterRoot: flutterRoot,
        log: _log(),
        downloader: _downloader(),
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

Uint8List _unixZip(Archive archive) {
  final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
  final data = ByteData.sublistView(bytes);
  for (var offset = 0; offset + 6 <= bytes.length; offset++) {
    if (data.getUint32(offset, Endian.little) == 0x02014b50) {
      data.setUint16(offset + 4, 0x0314, Endian.little);
    }
  }
  return bytes;
}

Log _log() => Log(output: NativeTestLogOutput());

final class NativeTestLogOutput implements LogOutput {
  @override
  bool get supportsAnsi => false;
  @override
  int get terminalColumns => 80;
  @override
  void stdout(String message) {}
  @override
  void stderr(String message) {}
  @override
  void write(String message) {}
}

Downloader _downloader() => Downloader(
  createClient: () => throw StateError(
    'Unexpected engine artifact download during isolated tests',
  ),
  log: _log(),
);
