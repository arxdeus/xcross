import 'dart:async';
import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/host/shared/darwin_toolchain_locations.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_target.dart';
import 'package:darwin_sdk_kit/target/simulator/simulator_target.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/host/linux/compose/linux_compose_host.dart';
import 'package:xcross/src/host/macos/compose/macos_compose_host.dart';
import 'package:xcross/src/host/windows/compose/windows_compose_host.dart';
import 'package:xcross/src/shared/compose/build/framework_build_stamp.dart';
import 'package:xcross/src/shared/compose/compose_host.dart';
import 'package:xcross/src/shared/compose/compose_simulator_signing.dart';
import 'package:xcross/src/shared/compose/kmp_project_detector.dart';
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
import 'package:xcross/src/shared/compose/watch/kotlin_source_watcher.dart';
import 'package:xcross/src/target/iphone/compose/iphone_compose_target.dart';
import 'package:xcross/src/target/shared/compose/compose_target.dart';
import 'package:xcross/src/target/simulator/compose/simulator_compose_target.dart';

@internal
ComposeTarget<PlatformHostInterface> fixtureIPhoneTargetFor(
  ComposeHost<PlatformHostInterface> host,
) => IPhoneComposeTarget(IPhoneTarget(host.host), host);
@internal
ComposeTarget<PlatformHostInterface> fixtureSimulatorTargetFor(
  ComposeHost<PlatformHostInterface> host,
) => SimulatorComposeTarget(
  SimulatorTarget(host.host),
  host,
  signing: FixtureSimulatorSigning(host.host),
);

@internal
final class FixtureSimulatorSigning
    implements ComposeSimulatorSigning<PlatformHostInterface> {
  const FixtureSimulatorSigning(this.host);
  @override
  final PlatformHostInterface host;
  @override
  Future<void> signBundle(String appPath) async {}
}

@internal
final class ComposeFixtureDarwinToolchainLocations
    implements DarwinToolchainLocationsInterface {
  const ComposeFixtureDarwinToolchainLocations();
  @override
  List<String> llvmToolDirectories() => const [];
  @override
  String get linkerInstallationHint => 'fixture linker';
  @override
  String get clangInstallationHint => 'fixture clang';
}

@internal
final class ComposeFixtureLogOutput implements LogOutput {
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
final class RemappedComposeFileSystem implements HostFileSystemInterface {
  RemappedComposeFileSystem(this.root);
  final String root;
  final List<String> requests = [];
  String resolve(String path) {
    requests.add(path);
    if (path == root || p.isWithin(root, path)) return path;
    return p.join(root, p.relative(path, from: '/virtual-compose'));
  }

  @override
  File file(String path) => File(resolve(path));
  @override
  Directory directory(String path) => Directory(resolve(path));
  @override
  Link link(String path) => Link(resolve(path));
  @override
  void makeExecutable(String path) => throw UnsupportedError('not expected');
  @override
  void setPermissions(String path, int mode) =>
      throw UnsupportedError('not expected');
  @override
  Future<void> createArchiveLink(String destination, String target) =>
      throw UnsupportedError('not expected');
}

@internal
final class ComposeTestSession {
  ComposeTestSession({
    required this.logOutput,
    required this.stdoutConsumer,
    required this.stderrConsumer,
    required this.temporaryRoot,
  }) {
    stdoutSink = IOSink(stdoutConsumer);
    stderrSink = IOSink(stderrConsumer);
    hosts = ComposeFixtureHosts(temporaryRoot.path);
    fixtureLog = Log(output: logOutput);
    fixtureDownloader = Downloader(
      createClient: () =>
          throw StateError('Tests must not download toolchains.'),
      log: fixtureLog,
    );
    fixtureIPhoneTarget = fixtureIPhoneTargetFor(hosts.linuxX64);
    fixtureSimulatorTarget = fixtureSimulatorTargetFor(hosts.macosArm64);
    fixtureRunner = fixtureProcessRunner(fixtureIPhoneTarget.host);
    fixtureTools = fixtureToolsFor(fixtureIPhoneTarget.host);
  }
  final Directory temporaryRoot;
  final ComposeFixtureByteConsumer stdoutConsumer;
  final ComposeFixtureByteConsumer stderrConsumer;
  final LogOutput logOutput;
  late final IOSink stdoutSink;
  late final IOSink stderrSink;
  late final ComposeFixtureHosts hosts;
  late final Log fixtureLog;
  late final Downloader fixtureDownloader;
  late final ComposeTarget<PlatformHostInterface> fixtureIPhoneTarget;
  late final ComposeTarget<PlatformHostInterface> fixtureSimulatorTarget;
  late final ProcessRunner<PlatformHostInterface> fixtureRunner;
  late final DarwinToolchainResolver<PlatformHostInterface> fixtureTools;
  ProcessRunner<T> fixtureProcessRunner<T extends PlatformHostInterface>(
    T host,
  ) => ProcessRunner(
    host,
    log: fixtureLog,
    stdinStream: const Stream<List<int>>.empty(),
    stdoutSink: stdoutSink,
    stderrSink: stderrSink,
  );
  DarwinToolchainResolver<PlatformHostInterface> fixtureToolsFor(
    PlatformHostInterface host,
  ) => DarwinToolchainResolver(
    fixtureProcessRunner(host),
    const ComposeFixtureDarwinToolchainLocations(),
  );
  DarwinSdkRepository<PlatformHostInterface> fixtureSdkRepositoryFor(
    PlatformHostInterface host,
  ) => DarwinSdkRepository(host, log: fixtureLog);
  KmpProject detectKmpProject(
    String root, {
    String? bundleId,
    String? appName,
    String gradleTarget = 'iosArm64',
  }) => KmpProjectDetector(
    files: fixtureRunner.host.fileSystem,
    log: fixtureLog,
    root: root,
    bundleIdOverride: bundleId,
    appNameOverride: appName,
    gradleTarget: gradleTarget,
  ).detect();
  FrameworkBuildStamp fixtureFrameworkStamp(String path) =>
      FrameworkBuildStamp.forFramework(
        path,
        files: fixtureRunner.host.fileSystem,
      );
  KotlinSourceWatcher fixtureSourceWatcher(
    String root, {
    List<String>? searchRoots,
  }) => KotlinSourceWatcher(
    root,
    files: fixtureRunner.host.fileSystem,
    searchRoots: searchRoots,
  );
  Future<void> dispose() async {
    await Future.wait([stdoutSink.close(), stderrSink.close()]);
    temporaryRoot.deleteSync(recursive: true);
  }
}

@internal
final class ComposeFixtureHosts {
  ComposeFixtureHosts(String temporaryRoot) {
    linuxX64 = LinuxComposeHost(
      LinuxHost(architecture: 'x64', temporaryDirectory: temporaryRoot),
    );
    windowsX64 = WindowsComposeHost(
      WindowsHost(
        architecture: 'x64',
        temporaryDirectory: temporaryRoot,
        fileSystem: linuxX64.host.fileSystem,
      ),
      runningExecutable: '/unused-xcross',
    );
    macosX64 = MacOSComposeHost(
      MacOSHost(
        architecture: 'x64',
        temporaryDirectory: temporaryRoot,
        fileSystem: linuxX64.host.fileSystem,
      ),
    );
    macosArm64 = MacOSComposeHost(
      MacOSHost(
        architecture: 'arm64',
        temporaryDirectory: temporaryRoot,
        fileSystem: linuxX64.host.fileSystem,
      ),
    );
  }
  late final ComposeHost<PlatformHostInterface> linuxX64;
  late final ComposeHost<PlatformHostInterface> windowsX64;
  late final ComposeHost<PlatformHostInterface> macosX64;
  late final ComposeHost<PlatformHostInterface> macosArm64;
}

@internal
final class ComposeFixtureByteConsumer implements StreamConsumer<List<int>> {
  final List<int> bytes = [];
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      bytes.addAll(chunk);
    }
  }

  @override
  Future<void> close() async {}
}

@internal
ComposeTestSession createComposeTestSession() => ComposeTestSession(
  logOutput: ComposeFixtureLogOutput(),
  stdoutConsumer: ComposeFixtureByteConsumer(),
  stderrConsumer: ComposeFixtureByteConsumer(),
  temporaryRoot: Directory.systemTemp.createTempSync('compose-session-'),
);
