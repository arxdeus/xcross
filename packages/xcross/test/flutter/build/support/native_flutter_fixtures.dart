import 'dart:async';
import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/shared/posix_paths.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/host/windows/windows_paths.dart';
import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:darwin_sdk_kit/host/linux/linux_darwin_toolchain_locations.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_target.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/linux/flutter/native_host_tools.dart';
import 'package:xcross/src/host/macos/flutter/native_host_tools.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';
import 'package:xcross/src/host/windows/flutter/native_host_tools.dart';
import 'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/shared/flutter/build/internal/flutter_tool_workspace.dart';
import 'package:xcross/src/shared/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

@internal
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
  if (sdkLocalEngine) {
    // A real `flutter precache --ios` framework records its engine, and off
    // macOS xcross only reuses SDK iOS artifacts that do.
    final framework = p.join(
      root,
      'bin',
      'cache',
      'artifacts',
      'engine',
      'ios',
      'Flutter.xcframework',
      'ios-arm64',
      'Flutter.framework',
    );
    File(p.join(framework, 'Flutter'))
      ..createSync(recursive: true)
      ..writeAsStringSync(label);
    File(p.join(framework, 'Info.plist')).writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>FlutterEngine</key><string>engine-hash</string></dict></plist>
''');
  }
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

@internal
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

@internal
Future<List<String>> nativeAssetTree(String root) async {
  final entries = await Directory(root)
      .list(recursive: true, followLinks: false)
      .map((entity) => p.relative(entity.path, from: root))
      .toList();
  entries.sort();
  return entries;
}

@internal
AppleToolShimResolver<LinuxHost> appleToolResolver({
  String? launcher,
  String? xcrun,
  bool declarative = false,
}) {
  final host = LinuxHost(architecture: 'arm64', paths: nativeFixturePaths());
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

@internal
PosixPaths nativeFixturePaths() => PosixPaths(context: p.Context());

@internal
WindowsHost windowsFixtureHost() => WindowsHost(
  architecture: 'x64',
  paths: WindowsFixturePaths(),
  processes: WindowsFixtureProcesses(WindowsHost().processes),
  environment: const {'PATH': '', 'PATHEXT': '.EXE'},
);

@internal
final class WindowsFixturePaths implements HostPathsInterface {
  WindowsFixturePaths();
  final PosixPaths _posix = PosixPaths();
  final WindowsPaths _windows = WindowsPaths();
  final p.Context _native = p.Context();
  @override
  p.Context get context => _native;
  @override
  String get configRoot => _posix.configRoot;
  @override
  String get cacheRoot => _posix.cacheRoot;
  @override
  String get temporaryRoot => _posix.temporaryRoot;
  @override
  String ioPath(String path) => _native.absolute(path);
  @override
  String executableName(String name, {String extension = '.exe'}) =>
      _posix.executableName(name, extension: extension);
  @override
  String pathKey(String path) => _native.normalize(_native.absolute(path));
  @override
  String toolNameKey(String name) => _windows.toolNameKey(name);
}

@internal
final class WindowsFixtureProcesses implements HostProcessInterface {
  WindowsFixtureProcesses(this.diagnostics);
  final HostProcessInterface diagnostics;
  @override
  ProcessExitDiagnostic describeExit(int exitCode) =>
      diagnostics.describeExit(exitCode);

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

@internal
final class LinkRecordingProcesses implements HostProcessInterface {
  final List<List<String>> arguments = [];
  @override
  ProcessExitDiagnostic describeExit(int exitCode) =>
      const ProcessExitDiagnostic(crashed: false, description: null);

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    this.arguments.add(arguments);
    return LinkRecordingChild();
  }

  @override
  Future<String?> findOnShellPath(
    String name, {
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async => name == 'cmd' ? r'C:\fixture\cmd.exe' : null;
  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) async {
    process.kill();
  }
}

@internal
final class LinkRecordingChild implements Process {
  @override
  final IOSink stdin = nativeTestSink();
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<int> get exitCode async => 0;
  @override
  int get pid => 1;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

@internal
List<(String, NativeHostTools, FlutterTargetBuildPolicy)> nativeHostCases() {
  final linuxArm = LinuxHost(
    architecture: 'arm64',
    paths: nativeFixturePaths(),
  );
  final linuxX64 = LinuxHost(architecture: 'x64', paths: nativeFixturePaths());
  final macArm = MacOSHost(architecture: 'arm64', paths: nativeFixturePaths());
  final macX64 = MacOSHost(architecture: 'x64', paths: nativeFixturePaths());
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

@internal
Log nativeTestLog() => Log(output: NativeTestLogOutput());

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

@internal
Downloader nativeTestDownloader() => Downloader(
  createClient: () => throw StateError(
    'Unexpected engine artifact download during isolated tests',
  ),
  log: nativeTestLog(),
);

@internal
IosEngineCache<LinuxHost> nativeLinuxEngineCache({
  required String flutterRoot,
  String? cacheRoot,
}) {
  final host = LinuxHost(architecture: 'arm64', paths: nativeFixturePaths());
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

@internal
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
