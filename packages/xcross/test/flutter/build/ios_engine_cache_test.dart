import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/shared/posix_paths.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_target.dart';
import 'package:darwin_sdk_kit/target/simulator/simulator_target.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:xcross/src/host/linux/flutter/native_host_tools.dart';
import 'package:xcross/src/host/macos/flutter/native_host_tools.dart';
import 'package:xcross/src/host/shared/flutter/engine_archive_writer.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';
import 'package:xcross/src/host/windows/flutter/native_host_tools.dart';
import 'package:xcross/src/shared/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
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
  final windowsArm = WindowsHost(architecture: 'arm64', paths: PosixPaths());
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
        (
          WindowsNativeHostTools(
            windowsArm,
            ProcessRunner(
              windowsArm,
              log: _log(),
              stdinStream: const Stream<List<int>>.empty(),
              stdoutSink: sink(),
              stderrSink: sink(),
            ),
          ),
          IPhoneFlutterTarget(IPhoneTarget(windowsArm)),
          'windows-arm64',
          'windows-arm64',
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
    final unsupported = WindowsHost(architecture: 'ia32');
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
  group('SDK engine revision (#93)', () {
    late String sdk;
    String userEngine(String leaf) =>
        p.join(cacheRoot, 'engine-hash', 'artifacts', 'engine', leaf);
    void writeStamp(String name, String revision) {
      File(p.join(flutterRoot, 'bin', 'cache', '$name.stamp'))
        ..createSync(recursive: true)
        ..writeAsStringSync('$revision\n');
    }

    void writeSdkCommon() {
      Directory(
        p.join(sdk, 'common', 'flutter_patched_sdk'),
      ).createSync(recursive: true);
      Directory(p.join(sdk, 'linux-arm64')).createSync(recursive: true);
      for (final name in ['vm_isolate_snapshot.bin', 'isolate_snapshot.bin']) {
        File(p.join(sdk, 'linux-arm64', name)).writeAsStringSync('snapshot');
      }
    }

    setUp(() {
      sdk = p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'engine');
    });

    test('reuses SDK iOS engine built for the current engine', () {
      _writeEngineFramework(
        p.join(sdk, 'ios', 'Flutter.xcframework', 'ios-arm64'),
        folded: false,
        engineRevision: 'engine-hash',
      );
      writeStamp('ios-sdk', 'older-hash');
      final engine = cache();
      expect(engine.sdkIosEngineRevision, 'engine-hash');
      expect(
        engine.flutterXcframework,
        p.join(sdk, 'ios', 'Flutter.xcframework'),
      );
    });

    test('skips SDK iOS engine whose framework names an older engine', () {
      _writeEngineFramework(
        p.join(sdk, 'ios', 'Flutter.xcframework', 'ios-arm64'),
        folded: false,
        engineRevision: 'older-hash',
      );
      writeStamp('ios-sdk', 'engine-hash');
      final engine = cache();
      expect(engine.sdkIosEngineRevision, 'older-hash');
      expect(
        engine.flutterXcframework,
        p.join(userEngine('ios'), 'Flutter.xcframework'),
      );
    });

    test('falls back to ios-sdk.stamp when the framework has no revision', () {
      _writeEngineFramework(
        p.join(sdk, 'ios', 'Flutter.xcframework', 'ios-arm64'),
        folded: false,
      );
      writeStamp('ios-sdk', 'older-hash');
      expect(
        cache().flutterXcframework,
        p.join(userEngine('ios'), 'Flutter.xcframework'),
      );
      writeStamp('ios-sdk', 'engine-hash');
      expect(
        cache().flutterXcframework,
        p.join(sdk, 'ios', 'Flutter.xcframework'),
      );
    });

    test('reads binary framework plists', () {
      final slice = p.join(sdk, 'ios', 'Flutter.xcframework', 'ios-arm64');
      _writeEngineFramework(slice, folded: false);
      File(p.join(slice, 'Flutter.framework', 'Info.plist')).writeAsBytesSync(
        Uint8List.sublistView(
          PropertyListSerialization.dataWithPropertyList({
            'FlutterEngine': 'older-hash',
          }),
        ),
      );
      expect(cache().sdkIosEngineRevision, 'older-hash');
    });

    test('skips SDK host snapshots and patched SDK from an older engine', () {
      writeSdkCommon();
      writeStamp('flutter_sdk', 'older-hash');
      final engine = cache();
      expect(engine.patchedSdkRoot, userEngine('common/flutter_patched_sdk'));
      expect(p.dirname(engine.vmSnapshotData), userEngine('linux-arm64'));
      writeStamp('flutter_sdk', 'engine-hash');
      expect(
        cache().patchedSdkRoot,
        p.join(sdk, 'common', 'flutter_patched_sdk'),
      );
      expect(p.dirname(cache().vmSnapshotData), p.join(sdk, 'linux-arm64'));
    });

    test('warns about every stale SDK artifact set before building', () async {
      _writeEngineFramework(
        p.join(sdk, 'ios', 'Flutter.xcframework', 'ios-arm64'),
        folded: false,
        engineRevision: 'older-hash',
      );
      writeSdkCommon();
      writeStamp('flutter_sdk', 'older-hash');
      writeStamp('engine-dart-sdk', 'older-hash');
      _writeEngineFramework(
        p.join(userEngine('ios'), 'Flutter.xcframework', 'ios-arm64'),
        folded: false,
        engineRevision: 'engine-hash',
      );
      Directory(
        userEngine('common/flutter_patched_sdk'),
      ).createSync(recursive: true);
      Directory(userEngine('linux-arm64')).createSync(recursive: true);
      for (final name in ['vm_isolate_snapshot.bin', 'isolate_snapshot.bin']) {
        File(p.join(userEngine('linux-arm64'), name)).writeAsStringSync('x');
      }
      final output = _RecordingLogOutput();
      final engine = IosEngineCache(
        targetPolicy: policy,
        hostTools: hostTools,
        flutterRoot: flutterRoot,
        cacheRoot: cacheRoot,
        log: Log(output: output),
        downloader: _downloader(),
      );
      await engine.ensureArtifactsAvailable();
      final warnings = output.stderrLines.join('\n');
      expect(warnings, contains('iOS engine artifacts are from engine older'));
      expect(warnings, contains('host engine artifacts are from engine older'));
      expect(warnings, contains('Dart SDK is from engine older-hash'));
      expect(warnings, contains('Invalid SDK hash'));
    });

    test('stays quiet when SDK artifacts match the engine', () async {
      _writeEngineFramework(
        p.join(sdk, 'ios', 'Flutter.xcframework', 'ios-arm64'),
        folded: false,
        engineRevision: 'engine-hash',
      );
      writeSdkCommon();
      for (final name in ['ios-sdk', 'flutter_sdk', 'engine-dart-sdk']) {
        writeStamp(name, 'engine-hash');
      }
      final output = _RecordingLogOutput();
      await IosEngineCache(
        targetPolicy: policy,
        hostTools: hostTools,
        flutterRoot: flutterRoot,
        cacheRoot: cacheRoot,
        log: Log(output: output),
        downloader: _downloader(),
      ).ensureArtifactsAvailable();
      expect(output.stderrLines, isEmpty);
    });
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
    _writeEngineFramework(
      p.join(sdk, 'ios', 'Flutter.xcframework', 'ios-arm64'),
      folded: false,
    );
    Directory(
      p.join(sdk, 'common', 'flutter_patched_sdk'),
    ).createSync(recursive: true);
    expect(
      engine.flutterXcframework,
      p.join(sdk, 'ios', 'Flutter.xcframework'),
    );
    expect(engine.patchedSdkRoot, p.join(sdk, 'common', 'flutter_patched_sdk'));
  });
  test('ignores SDK engine artifacts whose names were case-folded', () {
    final sdk = p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'engine');
    _writeEngineFramework(
      p.join(sdk, 'ios', 'Flutter.xcframework', 'ios-arm64'),
      folded: true,
    );
    expect(
      cache().flutterXcframework,
      p.join(
        cacheRoot,
        'engine-hash',
        'artifacts',
        'engine',
        'ios',
        'Flutter.xcframework',
      ),
    );
  });
}

void _writeEngineFramework(
  String slice, {
  required bool folded,
  String? engineRevision,
}) {
  final framework = Directory(p.join(slice, 'Flutter.framework'))
    ..createSync(recursive: true);
  for (final name in ['Flutter', 'Info.plist']) {
    File(
      p.join(framework.path, folded ? name.toLowerCase() : name),
    ).writeAsStringSync(
      name == 'Info.plist' && engineRevision != null
          ? PropertyListSerialization.stringWithPropertyList({
              'CFBundleExecutable': 'Flutter',
              'FlutterEngine': engineRevision,
            })
          : name,
    );
  }
}

final class _RecordingLogOutput implements LogOutput {
  final stderrLines = <String>[];
  @override
  bool get supportsAnsi => false;
  @override
  int get terminalColumns => 80;
  @override
  void stdout(String message) {}
  @override
  void stderr(String message) => stderrLines.add(message);
  @override
  void write(String message) {}
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

@internal
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
