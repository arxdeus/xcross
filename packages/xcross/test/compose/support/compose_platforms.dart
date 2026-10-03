import 'dart:io';
import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/build/framework_build_stamp.dart';
import 'package:xcross/src/compose/compose.dart';
import 'package:xcross/src/compose/watch/kotlin_source_watcher.dart';

abstract final class ComposeTestHosts {
  static final ComposeHost<PlatformHostInterface> linuxX64 = LinuxComposeHost(
    LinuxHost(
      architecture: 'x64',
      temporaryDirectory: Directory.systemTemp.path,
    ),
  );
  static final ComposeHost<PlatformHostInterface> windowsX64 =
      WindowsComposeHost(
        WindowsHost(
          architecture: 'x64',
          temporaryDirectory: Directory.systemTemp.path,
          fileSystem: ComposeTestHosts.linuxX64.host.fileSystem,
        ),
        runningExecutable: '/unused-xcross',
      );
  static final ComposeHost<PlatformHostInterface> macosX64 = MacOSComposeHost(
    MacOSHost(architecture: 'x64'),
  );
  static final ComposeHost<PlatformHostInterface> macosArm64 = MacOSComposeHost(
    MacOSHost(architecture: 'arm64'),
  );
}

ComposeTarget<PlatformHostInterface> fixtureTarget(
  ComposeHost<PlatformHostInterface> host, {
  bool simulator = false,
}) => simulator
    ? SimulatorComposeTarget(
        SimulatorTarget(host.host),
        host,
        signing: FixtureSimulatorSigning(host.host),
      )
    : IPhoneComposeTarget(IPhoneTarget(host.host), host);

final class FixtureSimulatorSigning
    implements ComposeSimulatorSigning<PlatformHostInterface> {
  const FixtureSimulatorSigning(this.host);
  @override
  final PlatformHostInterface host;
  @override
  Future<void> signBundle(String appPath) async {}
}

final fixtureIPhoneTarget = fixtureTarget(ComposeTestHosts.linuxX64);
final fixtureSimulatorTarget = fixtureTarget(
  ComposeTestHosts.macosArm64,
  simulator: true,
);
final fixtureRunner = ProcessRunner(
  log: fixtureLog,
  fixtureIPhoneTarget.host,
  stdinStream: const Stream<List<int>>.empty(),
  stdoutSink: stdout,
  stderrSink: stderr,
);
final fixtureTools = fixtureToolsFor(fixtureIPhoneTarget.host);
DarwinToolchainResolver<PlatformHostInterface> fixtureToolsFor(
  PlatformHostInterface host,
) => DarwinToolchainResolver(
  ProcessRunner(
    host,
    log: fixtureLog,
    stdinStream: const Stream<List<int>>.empty(),
    stdoutSink: stdout,
    stderrSink: stderr,
  ),
  const ComposeFixtureDarwinToolchainLocations(),
);

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

final fixtureLog = Log(output: ComposeFixtureLogOutput());

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

final fixtureDownloader = Downloader(
  createClient: () => throw StateError('Tests must not download toolchains.'),
  log: fixtureLog,
);

DarwinSdkRepository<PlatformHostInterface> fixtureSdkRepositoryFor(
  PlatformHostInterface host,
) => DarwinSdkRepository(host, log: fixtureLog);

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

ProcessRunner<T> fixtureProcessRunner<T extends PlatformHostInterface>(
  T host,
) => ProcessRunner(
  host,
  log: fixtureLog,
  stdinStream: const Stream<List<int>>.empty(),
  stdoutSink: stdout,
  stderrSink: stderr,
);
