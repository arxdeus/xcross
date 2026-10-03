import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/flutter/build/internal/flutter_tool_workspace.dart';
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/host/linux/flutter/native_host_tools.dart';
import 'package:xcross/src/host/macos/flutter/native_host_tools.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';
import 'package:xcross/src/host/windows/flutter/native_host_tools.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

IosEngineCache workspaceSdk(
  String root,
  String cacheRoot,
  String label, {
  bool sdkLocalEngine = false,
}) {
  for (final path in [
    p.join('packages', 'source'),
    p.join('bin', 'internal', 'source'),
    p.join('bin', 'cache', 'dart-sdk', 'source'),
    p.join('bin', 'cache', 'artifacts', 'fonts', 'source'),
    p.join('bin', 'cache', 'flutter_tools.snapshot'),
    if (sdkLocalEngine) ...[
      p.join('bin', 'cache', 'dart-sdk', 'bin', 'dart'),
      p.join(
        'bin',
        'cache',
        'artifacts',
        'engine',
        'ios',
        'Flutter.xcframework',
        'source',
      ),
      p.join(
        'bin',
        'cache',
        'artifacts',
        'engine',
        'linux-arm64',
        'vm_isolate_snapshot.bin',
      ),
      p.join(
        'bin',
        'cache',
        'artifacts',
        'engine',
        'linux-arm64',
        'isolate_snapshot.bin',
      ),
      p.join(
        'bin',
        'cache',
        'artifacts',
        'engine',
        'common',
        'flutter_patched_sdk',
        'source',
      ),
    ],
  ]) {
    File(p.join(root, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(label);
  }
  File(
    p.join(root, 'bin', 'internal', 'engine.version'),
  ).writeAsStringSync('engine-hash');
  final cache = nativeLinuxEngineCache(flutterRoot: root, cacheRoot: cacheRoot);
  Directory(cache.flutterXcframework).createSync(recursive: true);
  Directory(cache.patchedSdkRoot).createSync(recursive: true);
  File(cache.vmSnapshotData)
    ..createSync(recursive: true)
    ..writeAsStringSync(sdkLocalEngine ? label : 'host');
  File(
    cache.isolateSnapshotData,
  ).writeAsStringSync(sdkLocalEngine ? label : 'host');
  return cache;
}

void expectWorkspaceSdk(FlutterToolWorkspace workspace, String label) {
  for (final path in [
    p.join('packages', 'source'),
    p.join('bin', 'internal', 'source'),
    p.join('bin', 'cache', 'dart-sdk', 'source'),
    p.join('bin', 'cache', 'artifacts', 'fonts', 'source'),
    p.join('bin', 'cache', 'flutter_tools.snapshot'),
  ]) {
    expect(File(p.join(workspace.flutterRoot, path)).readAsStringSync(), label);
  }
}

Future<List<String>> nativeAssetTree(String root) async {
  final entries = await Directory(root)
      .list(recursive: true, followLinks: false)
      .map((entity) => p.relative(entity.path, from: root))
      .toList();
  entries.sort();
  return entries;
}

AppleToolShimResolver<LinuxHost> appleToolResolver({
  String? launcher,
  String? xcrun,
  bool declarative = false,
}) {
  final host = LinuxHost(architecture: 'arm64');
  final runner = ProcessRunner(
    host,
    log: nativeTestLog(),
    stdinStream: const Stream<List<int>>.empty(),
    stdoutSink: nativeTestSink(),
    stderrSink: nativeTestSink(),
  );
  return AppleToolShimResolver(
    IPhoneTarget(host),
    runner,
    DarwinSdkRepository(host, log: nativeTestLog()),
    DarwinToolchainResolver(runner, LinuxDarwinToolchainLocations(host)),
    launcher: launcher,
    xcrun: xcrun,
    declarative: declarative,
    hostTools: LinuxNativeHostTools(host, runner),
    executable: '/isolated/dart',
  );
}

WindowsHost windowsFixtureHost() => WindowsHost(
  architecture: 'x64',
  paths: PosixPaths(),
  processes: WindowsFixtureProcesses(),
  environment: const {'PATH': '', 'PATHEXT': '.EXE'},
);

final class WindowsFixtureProcesses implements HostProcessInterface {
  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    if (arguments.length == 5 && arguments[1] == 'mklink') {
      return Process.start('/bin/ln', [
        '-s',
        arguments[4],
        arguments[3],
      ], mode: mode);
    }
    return Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      mode: mode,
    );
  }

  @override
  Future<String?> findOnShellPath(
    String name, {
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async => name == 'cmd' ? '/fixture/cmd' : null;
  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) async {
    process.kill();
  }
}

List<(String, NativeHostTools, FlutterTargetBuildPolicy)> nativeHostCases() {
  final linuxArm = LinuxHost(architecture: 'arm64');
  final linuxX64 = LinuxHost(architecture: 'x64');
  final macArm = MacOSHost(architecture: 'arm64');
  final macX64 = MacOSHost(architecture: 'x64');
  final windows = windowsFixtureHost();
  return [
    (
      'linux-arm64',
      LinuxNativeHostTools(
        linuxArm,
        ProcessRunner(
          linuxArm,
          log: nativeTestLog(),
          stdinStream: const Stream<List<int>>.empty(),
          stdoutSink: nativeTestSink(),
          stderrSink: nativeTestSink(),
        ),
      ),
      IPhoneFlutterTarget(IPhoneTarget(linuxArm)),
    ),
    (
      'linux-x64',
      LinuxNativeHostTools(
        linuxX64,
        ProcessRunner(
          linuxX64,
          log: nativeTestLog(),
          stdinStream: const Stream<List<int>>.empty(),
          stdoutSink: nativeTestSink(),
          stderrSink: nativeTestSink(),
        ),
      ),
      IPhoneFlutterTarget(IPhoneTarget(linuxX64)),
    ),
    (
      'darwin-arm64',
      MacOSNativeHostTools(
        macArm,
        ProcessRunner(
          macArm,
          log: nativeTestLog(),
          stdinStream: const Stream<List<int>>.empty(),
          stdoutSink: nativeTestSink(),
          stderrSink: nativeTestSink(),
        ),
      ),
      IPhoneFlutterTarget(IPhoneTarget(macArm)),
    ),
    (
      'darwin-x64',
      MacOSNativeHostTools(
        macX64,
        ProcessRunner(
          macX64,
          log: nativeTestLog(),
          stdinStream: const Stream<List<int>>.empty(),
          stdoutSink: nativeTestSink(),
          stderrSink: nativeTestSink(),
        ),
      ),
      IPhoneFlutterTarget(IPhoneTarget(macX64)),
    ),
    (
      'windows-x64',
      WindowsNativeHostTools(
        windows,
        ProcessRunner(
          windows,
          log: nativeTestLog(),
          stdinStream: const Stream<List<int>>.empty(),
          stdoutSink: nativeTestSink(),
          stderrSink: nativeTestSink(),
        ),
      ),
      IPhoneFlutterTarget(IPhoneTarget(windows)),
    ),
  ];
}

Log nativeTestLog() => Log(output: NativeTestLogOutput());

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

Downloader nativeTestDownloader() => Downloader(
  createClient: () => throw StateError(
    'Unexpected engine artifact download during isolated tests',
  ),
  log: nativeTestLog(),
);

IosEngineCache<LinuxHost> nativeLinuxEngineCache({
  required String flutterRoot,
  String? cacheRoot,
}) {
  final host = LinuxHost(architecture: 'arm64');
  final log = nativeTestLog();
  final runner = ProcessRunner(
    host,
    log: log,
    stdinStream: const Stream<List<int>>.empty(),
    stdoutSink: nativeTestSink(),
    stderrSink: nativeTestSink(),
  );
  return IosEngineCache(
    targetPolicy: IPhoneFlutterTarget(IPhoneTarget(host)),
    hostTools: LinuxNativeHostTools(host, runner),
    flutterRoot: flutterRoot,
    cacheRoot: cacheRoot,
    log: log,
    downloader: nativeTestDownloader(),
  );
}

IOSink nativeTestSink() {
  final controller = StreamController<List<int>>();
  final subscription = controller.stream.listen((_) {});
  final sink = IOSink(controller.sink);
  addTearDown(() async {
    await sink.close();
    await subscription.cancel();
  });
  return sink;
}
